#!/usr/bin/env bash
# dsh-container 镜像冒烟测试: 对给定镜像做端到端验证, 覆盖 launch token
# 登录重定向、浏览器会话 cookie、Host/Origin 围栏、前端后处理、遥测默认关闭、
# 工具链分层布局、内置常用工具与容器内 podman 运行期环境、supervisor 重启与
# basic auth 全链路。
# 由 .github/workflows/image.yml 与 release-prep.yml 共同调用; 本地可用
# `just test` 运行。
#
# 用法: tests/smoke.sh <image> [--expect-dsh-version X.Y.Z]
#   <image>                 已构建(load/存在本地)的镜像引用
#   --expect-dsh-version    发布构建时传入镜像内 dsh 应等于的版本号
#                           (不含 dsh-v 前缀, 如 0.2.1-rc.2)
# 环境变量:
#   DOCKER    docker 二进制, 默认 docker; podman 用户可 DOCKER=podman
#   其他依赖: curl, awk, sed; 需要空闲端口 3081、127.0.0.1:3082 与 127.0.0.1:3083
#
# SC2016: 本文件大量使用 `"$DOCKER" exec "$cid" sh -c '...'` 形式, 单引号是
# **故意**的 —— 里面的 $ 必须留给容器内的 sh 展开, 而不是在宿主 shell 展开。
# shellcheck disable=SC2016
set -euo pipefail

DOCKER="${DOCKER:-docker}"
image=""
expect=""

usage() {
  echo "usage: tests/smoke.sh <image> [--expect-dsh-version X.Y.Z]" >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-dsh-version)
      [ $# -ge 2 ] || usage
      expect="$2"
      shift 2
      ;;
    --expect-dsh-version=*)
      expect="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [ -z "$image" ]; then
        image="$1"
        shift
      else
        echo "unexpected argument: $1" >&2
        usage
      fi
      ;;
  esac
done
[ -n "$image" ] || usage

cid=""
auth_cid=""
proxy_cid=""
cookie_jar="$(mktemp)"
cookie_relogin="$(mktemp)"
auth_cookie_jar="$(mktemp)"
auth_dsh_jar="$(mktemp)"
trap '"$DOCKER" rm -f "$cid" "$auth_cid" "$proxy_cid" >/dev/null 2>&1 || true; rm -f "$cookie_jar" "$cookie_relogin" "$auth_cookie_jar" "$auth_dsh_jar"' EXIT

# 失败辅助: 打印标记与容器日志后退出, 便于定位是哪一环、服务端发生了什么。
die() {
  echo "=== [smoke] FAIL: $*" >&2
  "$DOCKER" logs "$cid" >&2 2>&1 || true
  exit 1
}

# 桥接 + 端口映射, 与默认部署方式一致(对外端口 3081)。
cid="$("$DOCKER" run -d --rm --name dsh-smoke -p 3081:3081 \
  -e DSH_HOME=/tmp/dsh-smoke-home \
  "$image")"

# dsh web 启动后会把登录 URL(?token=...)打印到容器日志; 插件把同一个 token
# 写到 /tmp/dsh-caddy/launch-token, Caddy 用它把浏览器首次访问 302 到
# /?token=...。这里取日志 token, 同时验证 Caddy 的 Location 与它一致。
running() { [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
token=""
for _ in $(seq 1 60); do
  token="$("$DOCKER" logs "$cid" 2>&1 | grep -o 'token=[A-Za-z0-9_-]*' | head -n1 | cut -d= -f2 || true)"
  [ -n "$token" ] && break
  running "$cid" || { "$DOCKER" logs --tail 30 "$cid" >&2 || true; die "container exited before printing a login token"; }
  sleep 2
done
[ -n "$token" ] || { "$DOCKER" logs --tail 30 "$cid" >&2 || true; die "no login token printed by dsh web"; }

# 栈引导顺序: dsh web 先行, 插件写出 launch token 后 dsh-web 才拉起 Caddy。
# token 出现后等 3081 可连通再继续, 消除引导竞态。
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:3081/ 2>/dev/null && break
  running "$cid" || { "$DOCKER" logs --tail 30 "$cid" >&2 || true; die "container exited before the proxy became ready"; }
  sleep 1
done

# 1) 无会话 cookie 的 / 必须 302 到 /?token=...; 不能再像旧实现那样直接
# 返回页面(Caddy 不再注入 cookie)。Location 里的 token 必须与 dsh 日志一致。
redirect_headers="$(curl -sS -D - -o /dev/null http://127.0.0.1:3081/)"
printf '%s' "$redirect_headers" | grep -qi '^location: /?token=' \
  || die "GET / without a session cookie did not redirect to /?token=..."
redirect_status="$(printf '%s' "$redirect_headers" | sed -n '1s/.* \([0-9][0-9][0-9]\).*/\1/p')"
[ "$redirect_status" = "302" ] || die "GET / without a cookie returned $redirect_status, expected 302"
redirect_token="$(printf '%s' "$redirect_headers" | sed -n 's/^[Ll]ocation: \/?token=//p' | tr -d '\r')"
[ "$redirect_token" = "$token" ] \
  || die "Caddy redirect token does not match the dsh launch token"

# 2) token 交换由浏览器完成: dsh 303 + Set-Cookie(HttpOnly/SameSite=Strict);
# 浏览器之后自己携带 cookie, Caddy 不再注入。
exchange_headers="$(curl -sS -D - -o /dev/null -c "$cookie_jar" \
  "http://127.0.0.1:3081/?token=$token")"
printf '%s' "$exchange_headers" | grep -qi '^HTTP/1.1 303' \
  || die "token exchange did not return 303"
printf '%s' "$exchange_headers" | grep -qi 'set-cookie:.*HttpOnly' \
  || die "token exchange Set-Cookie lacks HttpOnly"
printf '%s' "$exchange_headers" | grep -qi 'set-cookie:.*SameSite=Strict' \
  || die "token exchange Set-Cookie lacks SameSite=Strict"

# 3) 浏览器持有 cookie 后 / 返回完整页面。
proxied_open="$(curl -fsS -b "$cookie_jar" http://127.0.0.1:3081/)" \
  || die "GET / with the browser session cookie failed"
[[ "$proxied_open" == *'<title>DeepSeek Harness</title>'* ]] \
  || die "proxied / with the session cookie does not serve the app"
# 鉴权职责没有后退到 dsh: 3080 直连(绕过 Caddy)无 cookie 仍必须 401,
# 同网段容器/进程无法绕过代理直接使用。
direct_unauth="$("$DOCKER" exec "$cid" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/)"
[ "$direct_unauth" = "401" ] || die "direct dsh (3080) without cookie returned $direct_unauth, expected 401"

# UI 默认 workspace bootstrap: dsh 通过 xdg-user-dir 解析系统 Documents 目录。
# 镜像必须带 xdg-user-dirs, entrypoint 必须提供 ~/Documents + user-dirs.dirs;
# 否则首屏会显示 "Unable to create default workspace"。
"$DOCKER" exec "$cid" sh -c 'test "$(xdg-user-dir DOCUMENTS)" = "$HOME/Documents" && test -d "$HOME/Documents"' \
  || die "xdg-user-dir DOCUMENTS is not provisioned by the image/entrypoint"
workspace_body="$(curl -sS -b "$cookie_jar" -X POST \
  http://127.0.0.1:3081/api/workspace/initializeDefault \
  -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"workspace/initializeDefault","payload":{"args":{}}}')"
[[ "$workspace_body" == *'"ok":true'* ]] \
  || die "workspace/initializeDefault failed: $workspace_body"
[[ "$workspace_body" == *'Documents/deepseek-harness/default-workspace'* ]] \
  || die "default workspace is not under Documents: $workspace_body"

# 首页必须 no-store: 防止镜像升级后浏览器沿用旧前端。
# 上游的索引入口有两个(dist 根 + 配置的 index path, 即 / 与 /index.html),
# 两个都必须禁缓存 —— 否则从 /index.html 进入的浏览器会缓存旧启动清单。
curl -sS -o /dev/null -D - -b "$cookie_jar" http://127.0.0.1:3081/ | grep -qi 'cache-control: no-store' \
  || die "GET / response lacks Cache-Control: no-store"
curl -sS -o /dev/null -D - -b "$cookie_jar" http://127.0.0.1:3081/index.html | grep -qi 'cache-control: no-store' \
  || die "GET /index.html response lacks Cache-Control: no-store (index entry caching not covered)"

# 会话内页面: 标题与前端补丁。先取回整个 index 再做包含判断,
# 避免 curl | grep -q 的 SIGPIPE/静默失败。
index_html="$(curl -fsS -b "$cookie_jar" http://127.0.0.1:3081/)" \
  || die "GET / with session cookie failed"
[[ "$index_html" == *'<title>DeepSeek Harness</title>'* ]] \
  || die "served index.html does not contain the expected title"
# 客户端 half 必须被 client-modules 扫描进 __DSH_BOOT__(Plugins 页的内置卡片);
# 这只是发现性断言, 卡片内容由 Playwright/人工预览覆盖。
[[ "$index_html" == *'"@dsh-container/adapt"'* ]] \
  || die "client half @dsh-container/adapt missing from __DSH_BOOT__"

# /assets/* 是 Vite 构建的内容哈希产物, 但 dsh 自己不给这棵树发任何缓存头
# (实测无 Cache-Control/ETag/Last-Modified) —— 少了 Caddy 补的 immutable, 浏览器
# 每次导航都要重下约 475 KiB 的 shell 资源。这里用索引里真正引用的第一个 assets
# JS 条目验证: 路径可达(200) 且响应带 immutable 头。资源请求同样要带会话 cookie。
asset_path="$(printf '%s' "$index_html" | grep -o 'assets/[A-Za-z0-9._-]\+\.js' | head -n1)"
[ -n "$asset_path" ] || die "served index references no hashed /assets JS entry"
asset_status="$(curl -sS -b "$cookie_jar" -o /dev/null -w '%{http_code}' "http://127.0.0.1:3081/$asset_path")"
[ "$asset_status" = "200" ] || die "GET /$asset_path returned $asset_status, expected 200"
curl -sS -b "$cookie_jar" -o /dev/null -D - "http://127.0.0.1:3081/$asset_path" \
  | grep -qi 'cache-control: public, max-age=31536000, immutable' \
  || die "GET /$asset_path lacks the immutable Cache-Control header (hashed asset caching not applied)"

# HEALTHCHECK 本身也要能被 Docker 判为 healthy。
health=""
for _ in $(seq 1 40); do
  health="$("$DOCKER" inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || true)"
  if [ "$health" = "healthy" ]; then break; fi
  sleep 2
done
[ "$health" = "healthy" ] || die "container health status is '$health', expected healthy"

# 工具链与 dsh 版本; 发布构建必须与官方仓库 tag 的版本号一致。
dsh_version="$("$DOCKER" exec "$cid" dsh --version | head -n1 | tr -d '\r\n' | sed 's/^v//')"
echo "$dsh_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' \
  || die "dsh --version output '$dsh_version' is not a semver"
if [ -n "$expect" ]; then
  [ "$dsh_version" = "$expect" ] \
    || die "dsh version '$dsh_version' does not match expected version $expect"
fi
"$DOCKER" exec "$cid" node --version | grep -Eq '^v[0-9]+\.' \
  || die "node version check failed"
"$DOCKER" exec "$cid" cargo --version | grep -Eq '^cargo [0-9]+\.' \
  || die "cargo version check failed"
"$DOCKER" exec "$cid" uv --version | grep -Eq '^uv [0-9]+\.' \
  || die "uv version check failed"
"$DOCKER" exec "$cid" pnpm --version | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' \
  || die "pnpm version check failed"
"$DOCKER" exec "$cid" podman --version | grep -Eq '^podman version [0-9]+\.' \
  || die "podman version check failed"
"$DOCKER" exec "$cid" gh --version | grep -Eq '^gh version [0-9]+\.' \
  || die "gh version check failed"

# 内置常用 CLI 工具(系统层烘干): agent 高频命令开箱可用, 不依赖容器内现装
# —— runtime apt install 落在可写层, 容器重建即丢, 所以常用的必须进镜像。
# fd 是 Debian fd-find(fdfind)的系统层真名别名。
# 第二组是本镜像运维面更依赖的诊断工具: 网络栈(Caddy→dsh、嵌套 podman 的
# slirp4netns)与进程排查。tcpdump/iftop/mtr 刻意不在其中 —— 容器没有
# CAP_NET_RAW, 装了也抓不到包(docs/deployment.md § Built-in tools)。
# just/shellcheck 让仓库自己的 justfile 与 lint 在容器内可跑。
"$DOCKER" exec "$cid" sh -c '
  for t in rg fd patch zip less vi nano ssh rsync wget tree htop sqlite3 tmux crun; do
    command -v "$t" >/dev/null || { echo "missing built-in tool: $t" >&2; exit 1; }
  done
  for t in dig nc socat traceroute iperf3 nft file ncdu strace zstd lz4 bc sponge pv uuidgen xdg-user-dir just shellcheck; do
    command -v "$t" >/dev/null || { echo "missing built-in diagnostics tool: $t" >&2; exit 1; }
  done
  python3 --version
  fd --version
  crun --version
  git lfs version
' || die "built-in tool check failed"

# yq 经 uv tool 装进镜像(非 apt): 二进制软链在 /usr/local/bin, venv 在
# /opt/uv-tools。它是 kislyuk 的 Python yq(4.x, 调用 /usr/bin/jq 处理 JSON),
# 因此版本行会顺带打印 jq 的版本。
"$DOCKER" exec "$cid" sh -c '
  test -x /usr/local/bin/yq || { echo "yq shim missing" >&2; exit 1; }
  test -d /opt/uv-tools/yq || { echo "yq venv missing" >&2; exit 1; }
  yq --version
' | grep -Eq '^yq [0-9]+\.' || die "yq is not the expected uv-tool install"

# pnpm 全局安装契约: pnpm 把可执行文件放在 $PNPM_HOME/bin, PATH 必须包含它。
# 断言解析结果 + PATH 成员, 而不是真去装一个包 —— 后者要拉 npm registry,
# 会让冒烟测试多一个网络依赖; 而"目录不在 PATH"正是 pnpm 自己报错拒装的
# 原因(旧镜像的回归: 装出来的命令不可见)。不设 pipefail 时管道右侧的
# grep 退出码即整条管道的结果, 符合这里的判据。
"$DOCKER" exec "$cid" sh -c '
  home="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
  pnpm_home="${PNPM_HOME:-$home/.local/share/pnpm}"
  bin="$(pnpm bin -g)" || exit 1
  test "$bin" = "$pnpm_home/bin" || { echo "pnpm global bin is \"$bin\", expected \"$pnpm_home/bin\"" >&2; exit 1; }
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "pnpm global bin \"$bin\" is not on PATH; pnpm add -g would refuse to install" >&2; exit 1 ;;
  esac
' || die "pnpm global install contract check failed"

# 容器内 rootless podman 运行期契约(podman 5.4.2 实测):
# XDG_RUNTIME_DIR 由 entrypoint provision; /etc/subuid、/etc/subgid 各自必须
# 只有一行 dsh 区间(重复行使 newuidmap 写出重叠映射, 内核 EINVAL, rootless
# podman 建不了 userns); 镜像不再导出 _CONTAINERS_USERNS_CONFIGURED=1 ——
# podman 5.x 下该变量让 rootless 侧跳过 userns 创建而 store/network 不初始化,
# 之后每条命令 nil panic; containers.conf 预设 slirp4netns + 空 default_sysctls。
"$DOCKER" exec "$cid" sh -c 'tr "\0" "\n" < /proc/1/environ | grep -Fx "XDG_RUNTIME_DIR=/run/user/1000"' \
  || die "entrypoint did not export XDG_RUNTIME_DIR=/run/user/1000"
"$DOCKER" exec "$cid" sh -c 'test -d /run/user/1000 && test -O /run/user/1000' \
  || die "XDG_RUNTIME_DIR not provisioned (or not owned by the runtime user)"
"$DOCKER" exec "$cid" sh -c 'test "$(grep -c "^dsh:100000:65536$" /etc/subuid)" = 1 && test "$(grep -c "^dsh:100000:65536$" /etc/subgid)" = 1' \
  || die "subuid/subgid must carry the dsh range exactly once (duplicates break newuidmap)"
"$DOCKER" exec "$cid" sh -c '! tr "\0" "\n" < /proc/1/environ | grep -Fxq "_CONTAINERS_USERNS_CONFIGURED=1"' \
  || die "_CONTAINERS_USERNS_CONFIGURED must NOT be set (breaks podman 5.x rootless)"
"$DOCKER" exec "$cid" sh -c 'grep -q "^default_rootless_network_cmd = \"slirp4netns\"$" /etc/containers/containers.conf' \
  || die "containers.conf must preset the rootless network command to slirp4netns"

# 分层布局: 工具链是镜像系统层真二进制(/usr/local/bin, /opt/rust),
# 卷上只有可写缓存与自装区 —— 路径解析与读写边界都必须成立。
"$DOCKER" exec "$cid" sh -c '
  home="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
  cargo_home="${CARGO_HOME:-$home/.cargo}"
  pnpm_home="${PNPM_HOME:-$home/.local/share/pnpm}"
  test "$(command -v uv)" = "/usr/local/bin/uv"
  test "$(command -v pnpm)" = "/usr/local/bin/pnpm"
  test "$(command -v cargo)" = "/usr/local/bin/cargo"
  test -d "${RUSTUP_HOME:-/opt/rust/rustup}/toolchains"
  # rustup 运行期必须能写 RUSTUP_HOME(settings/tmp/downloads/toolchains);
  # 容器重建后属主回到 root 的回归由 entrypoint 自愈兜底, 这里断言结果。
  test -w "${RUSTUP_HOME:-/opt/rust/rustup}"
  test -w "$cargo_home"
  test -w "$home/.local/bin"
  mkdir -p "$cargo_home/registry/cache" "$cargo_home/registry/index" "$pnpm_home"
' || die "toolchain/user-layer layout check failed"

# 旧卷工具副本不得遮蔽镜像真二进制: 种入旧 uv 后 PATH 镜像优先仍解析到
# /usr/local/bin/uv(清理不进镜像, 手动步骤见 docs/releasing.md)。
"$DOCKER" exec "$cid" sh -c 'home="$(getent passwd "$(id -u)" | cut -d: -f6)"; printf "#!/bin/sh\necho \"uv 0.0.1 (fake-old)\"\n" > "$home/.local/bin/uv" && chmod +x "$home/.local/bin/uv"'
"$DOCKER" exec "$cid" sh -c 'test "$(command -v uv)" = "/usr/local/bin/uv"' \
  || die "a stale volume uv copy shadows the image-provided uv"
"$DOCKER" exec "$cid" sh -c 'home="$(getent passwd "$(id -u)" | cut -d: -f6)"; rm -f "$home/.local/bin/uv"'
# Caddy 代理已在容器内运行(保留 Host/Origin + token 登录重定向)
"$DOCKER" exec "$cid" sh -c 'pgrep -x caddy >/dev/null' \
  || die "caddy process not found inside the container"
# 遥测默认关闭: entrypoint 必须把 DSH_TELEMETRY_MODE=DISABLED 传给 dsh web
# (用户点反馈时不会把完整会话上下文发往 harness-telemetry.deepseeksvc.com)。
# dsh web 是容器内唯一的常驻 node 进程(启动命令为 --profile web 形式,
# 不能按 "dsh web" 字样匹配; pgrep -f 会匹配到 exec 的 sh 自身)。
dsh_pid="$("$DOCKER" exec "$cid" sh -c 'pgrep -x node | head -n1' || true)"
[ -n "$dsh_pid" ] || die "dsh web process not found for telemetry env check"
"$DOCKER" exec "$cid" sh -c 'tr "\0" "\n" < "/proc/$1/environ" | grep -Fx "DSH_TELEMETRY_MODE=DISABLED"' _ "$dsh_pid" \
  || die "dsh web is not running with DSH_TELEMETRY_MODE=DISABLED"
# dsh 必须解析到镜像内版本 (卷中旧 npm 副本若存在也不得遮蔽)。
"$DOCKER" exec "$cid" sh -c '[ "$(command -v dsh)" = "/usr/local/bin/dsh" ]' \
  || die "dsh does not resolve to the image-provided /usr/local/bin/dsh"
"$DOCKER" exec "$cid" cat /etc/dsh-container/provenance.json | grep -q '"image":"ghcr.io/niyueee/dsh-container"' \
  || die "image provenance stamp missing or invalid"
# 镜像拥有全部工具链后, provenance 首次能如实记录实际工具版本
"$DOCKER" exec "$cid" jq -e '.tools.node and .tools.pnpm and .tools.rust and .tools.uv' \
  /etc/dsh-container/provenance.json >/dev/null \
  || die "provenance tool versions missing"

# supervisor 安全细节: launch token/Caddyfile 仅运行时用户可读; 旧的
# session-cookie 文件必须已被清理; Caddyfile 不再包含 header_up(不注入 cookie,
# 也不改写 Host/Origin), 但必须有登录重定向。
"$DOCKER" exec "$cid" sh -c \
  '[ "$(stat -c %a /tmp/dsh-caddy/launch-token)" = "600" ] && [ "$(stat -c %a /tmp/dsh-caddy/Caddyfile)" = "600" ] && [ ! -e /tmp/dsh-caddy/session-cookie ]' \
  || die "launch-token/Caddyfile permissions are not 0600 (or stale session-cookie exists)"
"$DOCKER" exec "$cid" sh -c '! grep -q "header_up" /tmp/dsh-caddy/Caddyfile' \
  || die "Caddyfile still rewrites/injects upstream headers (header_up present)"
"$DOCKER" exec "$cid" sh -c 'grep -q "redir @needsLogin" /tmp/dsh-caddy/Caddyfile' \
  || die "Caddyfile lacks the launch-token login redirect"
# launch token 由容器适配插件在 dsh 进程内写出。插件走 ctx.logger, 但本 profile
# 没有任何 console exporter, 因此插件自己注册了一个"只导出本插件日志"的
# exporter(见 index.js) —— 这一行同时钉住"日志确实落到了容器日志"。
"$DOCKER" logs "$cid" 2>&1 | grep -E 'dsh-container-adapt.*launch token written' \
  || die "container-adapt plugin did not write the launch token (or its log line is not visible)"
"$DOCKER" logs "$cid" 2>&1 | grep -F 'WARNING: the proxy listens on 0.0.0.0:3081 with NO authentication' \
  || die "no-auth proxy did not print the exposure warning"

# 特权 API(/api/settings/describe): 浏览器 cookie 经代理 200; 无 cookie 401;
# 3080 直连无 cookie 也必须 401 —— 同网段容器无法绕过代理拿特权接口。
settings_code="$(curl -sS -b "$cookie_jar" -o /dev/null -w '%{http_code}' -X POST \
  http://127.0.0.1:3081/api/settings/describe -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$settings_code" = "200" ] || die "proxied /api/settings/describe returned $settings_code, expected 200"
settings_nocookie="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  http://127.0.0.1:3081/api/settings/describe -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$settings_nocookie" = "401" ] || die "proxied API without cookie returned $settings_nocookie, expected 401"
direct_api="$("$DOCKER" exec "$cid" curl -s -o /dev/null -w '%{http_code}' -X POST \
  http://127.0.0.1:3080/api/settings/describe -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$direct_api" = "401" ] || die "direct dsh (3080) /api without cookie returned $direct_api, expected 401"

# 设置 > 打开配置文件按钮隐藏: 容器无桌面, 上游 openSettingsDocument 无
# headless 兜底 —— 插件包 settingsController 实例的 describe, 上游 describe
# 即返回 hasDocument:false。
settings_body="$(curl -sS -b "$cookie_jar" -X POST http://127.0.0.1:3081/api/settings/describe \
  -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[[ "$settings_body" == *'"hasDocument":false'* ]] \
  || die "settings describe did not report hasDocument:false (button-hide fuse broken): $settings_body"
# 旧下载入口已删除: /download/settings.yaml 只应落到前端 SPA fallback
# (HTML 页面), 任何 content-disposition: attachment 响应都意味着端点回归。
dl_gone="$(curl -sS -b "$cookie_jar" -D - -o /dev/null http://127.0.0.1:3081/download/settings.yaml)"
printf '%s' "$dl_gone" | grep -qi 'content-disposition: attachment' \
  && die "removed download endpoint still serves /download/settings.yaml"

# 最低支持 0.2.1-alpha.3: 不再注入 __DSH_TRANSPORT__ —— 0.2.1 上它唯一剩下的消费者
# 是设置文档 controller, 而按钮已由 hasDocument:false 隐藏; 这个负向断言防止
# 兼容层被无意间重新加回来。
[[ "$index_html" != *"__DSH_TRANSPORT__"* ]] \
  || die "served index unexpectedly carries the retired __DSH_TRANSPORT__ row"

# Host 允许列表: 默认只接受 loopback; 未授权的 dsh.test/evil.test 必须 403。
# 这正是 DNS rebinding 的防线 —— 不能像旧实现那样把任意 Host 改写成 loopback。
host_evil="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.test' http://127.0.0.1:3081/)"
[ "$host_evil" = "403" ] || die "Host: evil.test returned $host_evil, expected 403"
host_untrusted="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: dsh.test' http://127.0.0.1:3081/)"
[ "$host_untrusted" = "403" ] || die "Host: dsh.test returned $host_untrusted, expected 403 (not in the allowlist)"
# Origin 围栏: 带合法 cookie 但 Origin 不是本 authority, dsh 必须 403。
origin_evil="$(curl -sS -b "$cookie_jar" -o /dev/null -w '%{http_code}' \
  -H 'Origin: http://evil.test' -X POST http://127.0.0.1:3081/api/settings/describe \
  -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$origin_evil" = "403" ] || die "API with evil Origin returned $origin_evil, expected 403"
# 容器适配插件(container/plugin/)必须随镜像安装。
"$DOCKER" exec "$cid" sh -c 'test -f /opt/dsh-container-plugin/index.js && test -f /opt/dsh-container-plugin/overlay.yml && test -f /opt/dsh-container-plugin/scripts/extract-inline-assets.js && test -f /opt/dsh-container-plugin/scripts/minify-client.mjs && test -f /opt/dsh-container-plugin/scripts/refresh-build-record.mjs && test -d /opt/dsh-container-plugin/assets' \
  || die "container-adapt plugin files missing in the image"

# 客户端产物: 内联大图必须已抽成 /container-assets/<内容哈希> 文件, 产物必须已
# 压缩(minify 后处理)。合并包是 settings-account 所在的那个 57 模块 combo。
combo_url="$(grep -oE "plugins/\?\?[^\"' ]*" <<<"$index_html" | grep -m1 'dsh-client-ui-settings-account' || true)"
# 服务端渲染的索引把 URL 里的 & 转义成 &amp; —— 直接拿去 curl 会 404(参数名变成
# "amp;rev")。注意 bash 的 ${var//pat/rep} 里替换串的 & 表示"匹配到的文本", 必须写成
# \& 才是字面量 &, 否则等于没替换。
combo_url="${combo_url//&amp;/\&}"
case "$combo_url" in
  ''|/*) ;;
  *) combo_url="/$combo_url" ;;
esac
[ -n "$combo_url" ] || die "settings-account combo bundle URL not found in served index"
case "$combo_url" in
  *'&rev='*) ;;
  *) die "extracted combo URL has no rev parameter (did the index escaping change?): ${combo_url:0:120}" ;;
esac
combo_body="$(mktemp)"
combo_bytes="$(curl -fsS -b "$cookie_jar" --compressed -o "$combo_body" -w '%{size_download}' "http://127.0.0.1:3081${combo_url}")" \
  || die "fetching the combined client bundle failed"
# 抽图阈值是"解码后 >= 100 KiB" = base64 载荷 >= 136536 字符(4*ceil(102400/3))。
# 用 grep -oE + awk 而不是 `{136536,}` 这类巨大重复量词: 部分 grep(如 Debian 13 的
# 3.11)对这种量词直接报 "Regular expression too big" 并以 2 退出, 而 if 会把非零
# 当成"没命中", 断言就静默失效了。抽图后处理一旦没跑, 这里必然命中。
if grep -oE 'base64,[A-Za-z0-9+/=]+' "$combo_body" \
  | awk 'length($0) >= 136536 { hit = 1 } END { exit hit ? 0 : 1 }'; then
  die "served client bundle still inlines a large base64 image (extract-inline-assets did not run)"
fi
# 上游若自己改为 emit 文件, /container-assets 引用会消失 —— 那是正常演进, 只在下游
# 真有引用时验证路由; 但"大图内联"永远不允许回归(上面的断言)。
asset_path="$(grep -oE '/container-assets/[0-9a-f]{16,64}\.(png|jpeg|jpg|webp|gif)' "$combo_body" | head -n1 || true)"
if [ -n "$asset_path" ]; then
  asset_headers="$(curl -fsS -b "$cookie_jar" -D - -o /dev/null "http://127.0.0.1:3081${asset_path}")" \
    || die "GET ${asset_path} (extracted client image) failed"
  printf '%s' "$asset_headers" | grep -qi 'content-type: image/' \
    || die "${asset_path} is not served with an image content type"
  printf '%s' "$asset_headers" | grep -qi 'cache-control: public, max-age=31536000, immutable' \
    || die "${asset_path} lacks the immutable Cache-Control header"
fi
# minify 断言: 压缩后合并包实测约 1.0 MiB 线上字节(未处理基线为 5.06 MiB), 上限留 3 倍
# 余量。上游显著增长或 minify 步骤被跳过时会在这里失败 —— 那正是需要重新测量的信号。
[ "$combo_bytes" -lt 3145728 ] \
  || die "combined client bundle is ${combo_bytes} bytes gzipped; expected < 3 MiB (re-measure if upstream grew)"
rm -f "$combo_body"

# dsh web 守护/重启: dsh-restart 后 dsh-web 重新拉起, 新进程的 launch token 变化,
# Caddy 热更新 Location; 旧浏览器 cookie 仍有效(dsh 签名密钥持久化在卷上)。
"$DOCKER" exec "$cid" dsh-restart || die "dsh-restart failed"
token2=""
for _ in $(seq 1 90); do
  token2="$("$DOCKER" logs "$cid" 2>&1 | grep -o 'token=[A-Za-z0-9_-]*' | tail -n1 | cut -d= -f2 || true)"
  if [ -n "$token2" ] && [ "$token2" != "$token" ]; then break; fi
  sleep 1
done
if [ -z "$token2" ] || [ "$token2" = "$token" ]; then
  die "dsh-restart did not produce a new launch token"
fi

# Caddy 必须把新的 Location 收敛到新 token(supervisor 通过 caddy reload 热更新)。
redirect2_ok=0
for _ in $(seq 1 30); do
  loc2="$(curl -sS -D - -o /dev/null http://127.0.0.1:3081/ | sed -n 's/^[Ll]ocation: //p' | tr -d '\r')"
  case "$loc2" in
    *"token=$token2") redirect2_ok=1; break ;;
  esac
  sleep 1
done
[ "$redirect2_ok" = 1 ] || die "Caddy redirect did not converge to the new launch token after dsh-restart"

# 旧 token 必须失效; 新 token 交换 303; 新浏览器会话可用。
old_token_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3081/?token=$token" || true)"
[ "$old_token_code" = "401" ] || die "stale launch token returned $old_token_code, expected 401"
exchange2="$(curl -sS -o /dev/null -w '%{http_code}' -c "$cookie_relogin" \
  "http://127.0.0.1:3081/?token=$token2" || true)"
[ "$exchange2" = "303" ] || die "re-login after dsh-restart failed (last exchange=${exchange2:-none})"

# 会话跨 dsh web 重启存活: 重启前的浏览器 cookie 必须仍然 200(不依赖重新注入)。
survive=""
for _ in $(seq 1 15); do
  survive="$(curl -s -o /dev/null -w '%{http_code}' -b "$cookie_jar" http://127.0.0.1:3081/ || true)"
  [ "$survive" = "200" ] && break
  sleep 1
done
[ "$survive" = "200" ] \
  || die "browser session cookie did not survive dsh-restart (code=$survive)"
settings_restart=""
for _ in $(seq 1 15); do
  settings_restart="$(curl -s -b "$cookie_jar" -o /dev/null -w '%{http_code}' -X POST \
    http://127.0.0.1:3081/api/settings/describe -H 'content-type: application/json' \
    --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}' || true)"
  [ "$settings_restart" = "200" ] && break
  sleep 1
done
[ "$settings_restart" = "200" ] \
  || die "proxied /api/settings/describe after dsh-restart returned $settings_restart, expected 200"
index_restart="$(curl -fsS -b "$cookie_jar" http://127.0.0.1:3081/)" \
  || die "GET / after restart failed"
[[ "$index_restart" == *'<title>DeepSeek Harness</title>'* ]] \
  || die "served index.html after restart lacks the expected title"
[[ "$index_restart" != *"__DSH_TRANSPORT__"* ]] \
  || die "retired __DSH_TRANSPORT__ row reappeared after dsh web restart"

# basic auth 模式: 未带凭据 401; 带凭据后浏览器完成 token 登录; root/API 200;
# 受信任的 Host dsh.test 也必须能登录; WebSocket 只靠 dsh cookie(不要求 basic auth)。
auth_cid="$("$DOCKER" run -d --rm --name dsh-smoke-auth -p 127.0.0.1:3082:3081 \
  -e DSH_HOME=/tmp/dsh-smoke-auth-home \
  -e DSH_PUBLIC_URL=http://127.0.0.1:3082/ \
  -e DSH_TRUSTED_HOST=dsh.test \
  -e DSH_PROXY_USER=smoke \
  -e DSH_PROXY_PASSWORD=smoke-pass \
  "$image")"
auth_token=""
for _ in $(seq 1 60); do
  auth_token="$("$DOCKER" logs "$auth_cid" 2>&1 | grep -o 'token=[A-Za-z0-9_-]*' | head -n1 | cut -d= -f2 || true)"
  [ -n "$auth_token" ] && break
  running "$auth_cid" || { "$DOCKER" logs --tail 30 "$auth_cid" >&2 || true; die "basic-auth container exited before printing a login token"; }
  sleep 2
done
[ -n "$auth_token" ] || { "$DOCKER" logs --tail 30 "$auth_cid" >&2 || true; die "no login token printed by the basic-auth container"; }
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:3082/ 2>/dev/null && break
  running "$auth_cid" || { "$DOCKER" logs --tail 30 "$auth_cid" >&2 || true; die "basic-auth container exited before the proxy became ready"; }
  sleep 1
done
unauth="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3082/)"
[ "$unauth" = "401" ] || die "basic-auth proxy returned $unauth without credentials, expected 401"
unauth_body="$(curl -s http://127.0.0.1:3082/)"
case "$unauth_body" in *token=*) die "unauthenticated 401 leaked the launch token" ;; esac

# 浏览器流程: basic auth 之后 Caddy 302 到 token, dsh 303 Set-Cookie, 再 200。
auth_open="$(curl -sS -L -u smoke:smoke-pass -c "$auth_cookie_jar" -b "$auth_cookie_jar" \
  -o /dev/null -w '%{http_code}' http://127.0.0.1:3082/)"
[ "$auth_open" = "200" ] || die "basic-auth browser flow returned $auth_open, expected 200"
auth_exchange="$(curl -sS -u smoke:smoke-pass -o /dev/null -w '%{http_code}' -c "$auth_cookie_jar" \
  "http://127.0.0.1:3082/?token=$auth_token")"
[ "$auth_exchange" = "303" ] || die "basic-auth token exchange returned $auth_exchange, expected 303"
auth_root="$(curl -sS -u smoke:smoke-pass -b "$auth_cookie_jar" -o /dev/null -w '%{http_code}' http://127.0.0.1:3082/)"
[ "$auth_root" = "200" ] || die "basic-auth root with cookie returned $auth_root, expected 200"
auth_api="$(curl -sS -u smoke:smoke-pass -b "$auth_cookie_jar" -o /dev/null -w '%{http_code}' -X POST \
  http://127.0.0.1:3082/api/settings/describe -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$auth_api" = "200" ] || die "basic-auth API with cookie returned $auth_api, expected 200"

# 显式信任的 Host dsh.test: 登录与 API 都必须 200(同时覆盖 Caddy 允许列表和
# dsh --trusted-host 两侧一致)。
auth_dsh_open="$(curl -sS -L -u smoke:smoke-pass -H 'Host: dsh.test' \
  -c "$auth_dsh_jar" -b "$auth_dsh_jar" -o /dev/null -w '%{http_code}' http://127.0.0.1:3082/)"
[ "$auth_dsh_open" = "200" ] || die "trusted Host dsh.test login returned $auth_dsh_open, expected 200"
auth_dsh_api="$(curl -sS -u smoke:smoke-pass -H 'Host: dsh.test' -b "$auth_dsh_jar" \
  -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3082/api/settings/describe \
  -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$auth_dsh_api" = "200" ] || die "trusted Host dsh.test API returned $auth_dsh_api, expected 200"
auth_evil="$(curl -sS -u smoke:smoke-pass -o /dev/null -w '%{http_code}' -H 'Host: evil.test' http://127.0.0.1:3082/)"
[ "$auth_evil" = "403" ] || die "untrusted Host on basic-auth proxy returned $auth_evil, expected 403"

# WebSocket: 浏览器不保证给升级请求带 Authorization, 所以 Caddy 对 WS 路径不做
# basic auth; dsh 的 SameSite=Strict cookie 仍是唯一凭据。
ws() { curl -sS --http1.1 -i --max-time 3 -o /tmp/dsh-smoke-ws.out \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "$@" http://127.0.0.1:3082/api/remote.mux >/dev/null 2>&1 || true; head -1 /tmp/dsh-smoke-ws.out; }
ws_ok="$(ws -H 'Host: dsh.test' -b "$auth_dsh_jar")"
case "$ws_ok" in *'101 Switching Protocols'*) ;; *) die "cookie-only WebSocket handshake returned: $ws_ok" ;; esac
ws_denied="$(ws -H 'Host: dsh.test')"
case "$ws_denied" in *'401 Unauthorized'*) ;; *) die "WebSocket without cookie returned: $ws_denied" ;; esac
rm -f /tmp/dsh-smoke-ws.out

# 只设置 basic auth 一半变量时必须 fail closed, 不能静默裸奔。
if timeout 30 "$DOCKER" run --rm --name dsh-smoke-partial-auth \
    -e DSH_HOME=/tmp/dsh-smoke-partial-home \
    -e DSH_PROXY_USER=smoke \
    "$image" >/tmp/dsh-partial-auth.log 2>&1; then
  echo "container with only DSH_PROXY_USER set unexpectedly started" >&2
  cat /tmp/dsh-partial-auth.log >&2 || true
  exit 1
fi
grep -F 'must be set together' /tmp/dsh-partial-auth.log >/dev/null \
  || die "partial-auth container failed without the expected message"

# 出站代理环境变量回归: network-proxy 文档会要求 HTTP(S)_PROXY; 容器内部探针
# 必须 --noproxy 直连回环, 否则 wait_for_dsh_port/健康检查会走代理并失败。
proxy_cid="$("$DOCKER" run -d --rm --name dsh-smoke-proxy -p 127.0.0.1:3083:3081 \
  -e DSH_HOME=/tmp/dsh-smoke-proxy-home \
  -e HTTP_PROXY=http://127.0.0.1:9 \
  -e HTTPS_PROXY=http://127.0.0.1:9 \
  -e ALL_PROXY=http://127.0.0.1:9 \
  -e NODE_USE_ENV_PROXY=1 \
  "$image")"
proxy_ready=0
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3083/ 2>/dev/null || true)"
  if [ "$code" = "302" ] || [ "$code" = "401" ]; then proxy_ready=1; break; fi
  running "$proxy_cid" || { "$DOCKER" logs --tail 40 "$proxy_cid" >&2 || true; die "proxy-env container exited during startup"; }
  sleep 1
done
[ "$proxy_ready" = 1 ] || { "$DOCKER" logs --tail 40 "$proxy_cid" >&2 || true; die "proxy-env container did not become reachable (internal probes went through HTTP_PROXY?)"; }
proxy_health=""
for _ in $(seq 1 40); do
  proxy_health="$("$DOCKER" inspect -f '{{.State.Health.Status}}' "$proxy_cid" 2>/dev/null || true)"
  [ "$proxy_health" = "healthy" ] && break
  sleep 2
done
[ "$proxy_health" = "healthy" ] || { "$DOCKER" logs --tail 40 "$proxy_cid" >&2 || true; die "proxy-env container health is '$proxy_health', expected healthy"; }
"$DOCKER" rm -f "$proxy_cid" >/dev/null 2>&1 || true
proxy_cid=""

# issue #12 回归(同容器重启路径): 旧实现把"cookie 文件被写了一次"当成就绪
# 信号, 复用旧 cookie 时插件不写盘, dsh-web 空等 120s 后 exit 1。新实现每次
# dsh 重启都删掉旧 token 并等新 token; 这里真等过 120s 窗口, 确认容器仍在运行、
# 旧浏览器 cookie 仍有效、代理可用。
"$DOCKER" restart "$cid" >/dev/null || die "docker restart failed"
restart_root=""
for _ in $(seq 1 60); do
  restart_root="$(curl -s -o /dev/null -w '%{http_code}' -b "$cookie_jar" http://127.0.0.1:3081/ || true)"
  [ "$restart_root" = "200" ] && break
  running "$cid" || { "$DOCKER" logs --tail 40 "$cid" >&2 || true; die "container exited while coming back from docker restart"; }
  sleep 1
done
[ "$restart_root" = "200" ] \
  || die "browser session after docker restart returned $restart_root, expected 200"
sleep 130
running "$cid" \
  || { "$DOCKER" logs --tail 40 "$cid" >&2 || true; die "container exited within 130s of docker restart (issue #12 regression)"; }
restart_root_late="$(curl -s -o /dev/null -w '%{http_code}' -b "$cookie_jar" http://127.0.0.1:3081/ || true)"
[ "$restart_root_late" = "200" ] \
  || die "browser session 130s after docker restart returned $restart_root_late, expected 200"

echo "=== [smoke] PASS: all checks passed for $image"
