#!/usr/bin/env bash
# dsh-container 上游契约静态检查: 对给定上游 dsh tag 的源码做 grep 级核对,
# 判定本镜像所依赖的上游行为是否仍然成立(契约清单见 docs/upstream-contract.md,
# 本脚本是该文档的机器可核对形态 —— 两者需同步更新)。
#
# 与 tests/smoke.sh 的分工: contract.sh 在"构建镜像之前"用几秒钟判定是否有
# 兼容漂移(补丁锚点/CLI 契约/围栏机制), 让 release-prep 流水线尽早决定
# 走"直接发版"还是"唤醒 agent 修复"; smoke.sh 则在构建后做行为级验证。
#
# 用法:
#   tests/contract.sh --tag dsh-v0.1.2-rc.1 [--repo OWNER/REPO] [--dir PATH]
#     --tag   上游 dsh-v* tag(必填)
#     --repo  上游仓库, 默认 deepseek-ai/deepseek-harness
#     --dir   已有 checkout 路径(本地调试用, 跳过 clone)
# 退出码: 0 = 契约完好; 2 = 检测到漂移(有 critical 项 MISS); 1 = 基础设施错误
# 输出行格式: "PASS|MISS|WARN|SKIP <check-id>[ <detail>]", 供 workflow 解析。
set -euo pipefail

UPSTREAM_REPO="deepseek-ai/deepseek-harness"
TAG=""
DIR=""

usage() {
  echo "usage: tests/contract.sh --tag dsh-vX.Y.Z [--repo OWNER/REPO] [--dir PATH]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) [ $# -ge 2 ] || usage; TAG="$2"; shift 2 ;;
    --tag=*) TAG="${1#*=}"; shift ;;
    --repo) [ $# -ge 2 ] || usage; UPSTREAM_REPO="$2"; shift 2 ;;
    --repo=*) UPSTREAM_REPO="${1#*=}"; shift ;;
    --dir) [ $# -ge 2 ] || usage; DIR="$2"; shift 2 ;;
    --dir=*) DIR="${1#*=}"; shift ;;
    -h|--help) usage ;;
    *) echo "unexpected argument: $1" >&2; usage ;;
  esac
done

[ -n "$TAG" ] || usage
# 与 upstream-tag.yml 的 semver 解析保持一致的 tag 形状校验
if ! [[ "$TAG" =~ ^dsh-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: --tag must look like dsh-vX.Y.Z[-pre], got: $TAG" >&2
  exit 1
fi

WORK=""
if [ -z "$DIR" ]; then
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  ROOT="$WORK/upstream"
  echo "[contract] cloning $UPSTREAM_REPO at $TAG (shallow)..."
  clone_ok=0
  for _ in 1 2 3; do
    # 公共仓库 HTTPS shallow clone 无需认证; 网络抖动重试三次
    if git clone --quiet --depth 1 --branch "$TAG" \
        "https://github.com/$UPSTREAM_REPO.git" "$ROOT" 2>/dev/null; then
      clone_ok=1
      break
    fi
    sleep 3
  done
  [ "$clone_ok" = 1 ] || { echo "error: failed to clone $UPSTREAM_REPO at $TAG" >&2; exit 1; }
else
  ROOT="$DIR"
  [ -d "$ROOT" ] || { echo "error: --dir $ROOT does not exist" >&2; exit 1; }
  trap - EXIT
fi

pass=0; miss=0; warn=0
declare -a MISSED=()

# 在指定相对路径下递归找固定字符串(grep -F, 跳过 node_modules/.git)。
# 排除文档类文件: README/文档里出现某字符串不算机器可核对的锚点, 否则
# flag 被从代码里删掉但 README 还提及时会 false-PASS。
found_in() { # <rel-root> <fixed-string> -> 0/1
  grep -rIsF --exclude-dir=node_modules --exclude-dir=.git \
    --exclude='*.md' --exclude='*.i18n.yaml' \
    -e "$2" "$ROOT/$1" >/dev/null 2>&1
}

# critical: 前端补丁锚点的源形态 —— container/plugin/scripts/patch-client.js
# 的候选串由它编译而来。
# 源码里两个特征同时成立才认为补丁锚点未漂移(connection/src/client/index.ts)。
if [ -f "$ROOT/packages/client/connection/src/client/index.ts" ]; then
  f="$ROOT/packages/client/connection/src/client/index.ts"
  if grep -qF 'isLoopbackHostname(pageLocation.hostname)' "$f" \
      && grep -qF 'transport?.ownsHost === true' "$f"; then
    echo "PASS connection.isLoopback.source"
    pass=$((pass + 1))
  else
    echo "MISS connection.isLoopback.source (isLoopback expression changed or removed)"
    MISSED+=("connection.isLoopback.source"); miss=$((miss + 1))
  fi
else
  echo "MISS connection.isLoopback.source (packages/client/connection/src/client/index.ts not found)"
  MISSED+=("connection.isLoopback.source"); miss=$((miss + 1))
fi

# critical: 编译产物里的补丁候选串(若上游把 lib/ 提交进仓库才存在;
# 源码构建时该文件由 pnpm build 生成, 此时 SKIP, 由 smoke 做行为级验证)。
if [ -f "$ROOT/packages/client/connection/lib/client.js" ]; then
  if grep -qF 'isLoopback: transport?.ownsHost === true || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),' \
      "$ROOT/packages/client/connection/lib/client.js"; then
    echo "PASS connection.isLoopback.built"
    pass=$((pass + 1))
  else
    echo "MISS connection.isLoopback.built (built candidate string not found)"
    MISSED+=("connection.isLoopback.built"); miss=$((miss + 1))
  fi
else
  echo "SKIP connection.isLoopback.built (lib/ not committed; verified behaviorally by smoke)"
fi

# critical: /api 信任围栏 —— Caddy 头改写放行的前提是围栏仍按 HTTP 头
# (Host/Origin/sec-fetch-site)判断且实现位于 api-request-trust.ts。上游没有
# 名为 PRIVILEGED_METHODS 的标识符(那是本仓库对该机制的描述名, 见 AGENTS.md),
# 特权方法经代理可达的行为由 smoke 的 /api/settings/describe 断言验证。
fence="$ROOT/packages/client/connection/src/api-request-trust.ts"
if [ -f "$fence" ] \
    && grep -qF 'sec-fetch-site' "$fence" \
    && grep -qF 'isLoopbackHostname' "$fence"; then
  echo "PASS server.request_fence"
  pass=$((pass + 1))
else
  echo "MISS server.request_fence (header-based trust fence missing or redesigned)"
  MISSED+=("server.request_fence"); miss=$((miss + 1))
fi

# critical: dsh web CLI 契约 —— entrypoint 解析 --port, dsh-web 追加 --no-open,
# 并挂载插件 overlay(--patch 是 launcher 根 flag, 与 --profile web 组合使用;
# 注意上游的 web 别名会 rejectParentOptions 拒绝父级 --patch)。
for flag in -- --no-open --port --patch; do
  [ "$flag" = "--" ] && continue
  id="cli.${flag#--}"
  if found_in "." "$flag"; then
    echo "PASS $id"
    pass=$((pass + 1))
  else
    echo "MISS $id (flag string not found in upstream source)"
    MISSED+=("$id"); miss=$((miss + 1))
  fi
done

# warn: 一次性登录 URL 行为由 smoke 做行为级验证, 这里仅提示性检查。
if found_in "." "token="; then
  echo "PASS web.token_url"
  pass=$((pass + 1))
else
  echo "WARN web.token_url ('token=' not found; login-URL flow may have changed, rely on smoke)"
  warn=$((warn + 1))
fi

# critical: 容器适配插件(container/plugin/)依赖的上游 API 锚点 —— 会话
# cookie 自举用 ctx.connection.authenticatedUrl() 取进程 token、webServer.port
# 定位内部端口; "打开配置文件"按钮隐藏依赖两条上游行为: describe 的
# hasDocument 直接取 provider.documentPath(插件把实例的 documentPath 置为
# undefined 即翻转), 以及 SettingsDocumentAction 在状态非 ready 时不渲染。
if grep -qF 'authenticatedUrl' "$ROOT/packages/client/connection/src/rpc.ts"; then
  echo "PASS plugin.authenticated_url"
  pass=$((pass + 1))
else
  echo "MISS plugin.authenticated_url (Connection.authenticatedUrl missing or renamed)"
  MISSED+=("plugin.authenticated_url"); miss=$((miss + 1))
fi
if grep -qF 'hasDocument: settings.documentPath !== undefined' "$ROOT/packages/api/settings-controller/src/index.ts"; then
  echo "PASS plugin.settings_document_hidden"
  pass=$((pass + 1))
else
  echo "MISS plugin.settings_document_hidden (describe no longer derives hasDocument from provider.documentPath)"
  MISSED+=("plugin.settings_document_hidden"); miss=$((miss + 1))
fi
if grep -qF "state.status !== 'ready'" "$ROOT/packages/client/ui-settings-general/src/client/SettingsDocumentAction.tsx"; then
  echo "PASS plugin.settings_action_gate"
  pass=$((pass + 1))
else
  echo "MISS plugin.settings_action_gate (SettingsDocumentAction no longer skips rendering when not ready)"
  MISSED+=("plugin.settings_action_gate"); miss=$((miss + 1))
fi

# warn: 上游新增的 trustedHosts 只作用于服务端请求围栏(见
# container/plugin/scripts/patch-client.js 头注), 出现不算漂移, 但提醒
# 审阅者确认浏览器侧补丁仍然必需。
if found_in "." "trustedHosts"; then
  echo "WARN web.trusted_hosts (trustedHosts present upstream; confirm client-side patch still required)"
  warn=$((warn + 1))
else
  echo "SKIP web.trusted_hosts (not present upstream)"
fi

echo "contract check: $pass pass, $miss miss, $warn warn"
if [ "$miss" -gt 0 ]; then
  echo "DRIFT: ${MISSED[*]}"
  exit 2
fi
echo "CONTRACT OK: $TAG satisfies all critical checks"
