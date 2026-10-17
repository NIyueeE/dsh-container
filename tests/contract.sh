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

# critical: 传输层声明的源锚点。
# 源码锚点: connection 的 isLoopback 计算必须仍带 ownsHost 分支 —— 容器适配插件
# 为老 tag 保留 __DSH_TRANSPORT__={ownsHost:true} 行; 0.2.x 上只剩 settings-document
# controller 消费 isLoopback(已被 hasDocument:false 隐藏), 所以这行不是安全机制。
# 若上游改名/去掉该分支, 老 tag 兼容层即失去意义(行为级断言在 smoke 的索引
# 渲染检查与 tests/plugin-unit.mjs)。
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

# critical: /api 信任围栏 —— Caddy 现在保留浏览器 Host/Origin, 由 dsh 的
# 围栏直接判定; 外部 authority 必须经 --trusted-host 授权。围栏仍按 HTTP 头
# (Host/Origin/sec-fetch-site)判断且实现位于 api-request-trust.ts。上游没有
# 名为 PRIVILEGED_METHODS 的标识符(那是本仓库对该机制的描述名), 特权方法经
# 代理可达的行为由 smoke 的 /api/settings/describe 断言验证。
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
for flag in -- --no-open --port --patch --trusted-host; do
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

# critical: 容器适配插件(container/plugin/)依赖的上游 API 锚点 —— launch
# token 写入用 ctx.connection.authenticatedUrl() 取进程 token、webServer.port
# 定位内部端口; "打开配置文件"按钮隐藏依赖两条上游行为: describe 的
# hasDocument 取值方式(v0.1.7+ 是硬编码 true, 更早是 provider.documentPath
# 推导), 以及 SettingsDocumentAction 在状态非 ready 时不渲染。
if grep -qF 'authenticatedUrl' "$ROOT/packages/client/connection/src/rpc.ts"; then
  echo "PASS plugin.authenticated_url"
  pass=$((pass + 1))
else
  echo "MISS plugin.authenticated_url (Connection.authenticatedUrl missing or renamed)"
  MISSED+=("plugin.authenticated_url"); miss=$((miss + 1))
fi
# v0.1.7+: describe 硬编码 hasDocument: true —— 插件的 describe 包装是唯一
# 的抑制手段, 该硬编码就是"补丁必须存在"的证据(消失反而是好事: 说明上游
# 改了机制, 需重新核对插件)。
if grep -qF 'hasDocument: true' "$ROOT/packages/api/settings-controller/src/index.ts"; then
  echo "PASS plugin.settings_document_hidden (v0.1.7+ describe hardcodes hasDocument; the plugin wraps it)"
  pass=$((pass + 1))
elif grep -qF 'hasDocument: settings.documentPath !== undefined' "$ROOT/packages/api/settings-controller/src/index.ts"; then
  # 旧 tag: hasDocument 由 provider.documentPath 推导, 插件翻该属性。
  echo "PASS plugin.settings_document_hidden (legacy: describe derives hasDocument from provider.documentPath; the plugin flips it)"
  pass=$((pass + 1))
else
  echo "MISS plugin.settings_document_hidden (describe no longer derives/hardcodes hasDocument as expected; re-check the plugin adaptation)"
  MISSED+=("plugin.settings_document_hidden"); miss=$((miss + 1))
fi
if grep -qF "state.status !== 'ready'" "$ROOT/packages/client/ui-settings-general/src/client/SettingsDocumentAction.tsx"; then
  echo "PASS plugin.settings_action_gate"
  pass=$((pass + 1))
else
  echo "MISS plugin.settings_action_gate (SettingsDocumentAction no longer skips rendering when not ready)"
  MISSED+=("plugin.settings_action_gate"); miss=$((miss + 1))
fi

# critical(隐私): 镜像默认 DSH_TELEMETRY_MODE=DISABLED(见 container/entrypoint.sh)
# 之所以能关掉遥测, 靠的是上游 base bundle 把这个环境变量接到
# session-telemetry-otel 的 mode 配置上; 上游默认是 FEEDBACK_ONLY(显式提交反馈
# 时才上传会话前缀)。一旦上游改名/换默认值, 我们的默认就静默失效 —— 属于隐私
# 面漂移, 必须修复或显式改默认, 不能默认接受。
telemetry="$ROOT/packages/bundle/base/cordis.patch.yml"
if [ -f "$telemetry" ] \
    && grep -qF 'session-telemetry-otel' "$telemetry" \
    && grep -qF 'process.env.DSH_TELEMETRY_MODE' "$telemetry"; then
  echo "PASS telemetry.default_off (base bundle maps DSH_TELEMETRY_MODE to the session-telemetry-otel mode)"
  pass=$((pass + 1))
else
  echo "MISS telemetry.default_off (DSH_TELEMETRY_MODE no longer feeds session-telemetry-otel; the image telemetry default-off no longer holds)"
  MISSED+=("telemetry.default_off"); miss=$((miss + 1))
fi

# critical: 服务端围栏必须真正消费 trustedHosts —— 新模型用 --trusted-host 授权
# 外部 authority, 而不是把 Host 改写成 loopback。没有这个分支, 远程部署会 403。
if [ -f "$fence" ] && grep -qF trustedHosts "$fence"; then
  echo "PASS server.trusted_hosts (fence consumes trustedHosts)"
  pass=$((pass + 1))
else
  echo "MISS server.trusted_hosts (fence does not consume trustedHosts; the no-rewrite proxy model cannot authorize external authorities)"
  MISSED+=("server.trusted_hosts"); miss=$((miss + 1))
fi

# warn: --public-url 从 0.2.1-alpha.1 才有; dsh-web 会探测并跳过, 只退化公告
# 地址, 不影响 token 重定向/围栏。老 tag 仍可构建。
if found_in "." "--public-url"; then
  echo "PASS web.public_url"
  pass=$((pass + 1))
else
  echo "WARN web.public_url (not present; dsh-web skips --public-url and advertises the bind address)"
  warn=$((warn + 1))
fi

echo "contract check: $pass pass, $miss miss, $warn warn"
if [ "$miss" -gt 0 ]; then
  echo "DRIFT: ${MISSED[*]}"
  exit 2
fi
echo "CONTRACT OK: $TAG satisfies all critical checks"
