#!/usr/bin/env bash
# dsh-container 镜像冒烟测试: 对给定镜像做端到端验证, 覆盖 token 交换、
# Caddy 头改写、会话注入、前端补丁、工具链分层布局、supervisor 重启与
# basic auth 全链路。由 .github/workflows/image.yml 与 release-prep.yml
# 共同调用; 本地可用 `just test` 运行。
#
# 用法: tests/smoke.sh <image> [--expect-dsh-version X.Y.Z]
#   <image>                 已构建(load/存在本地)的镜像引用
#   --expect-dsh-version    发布构建时传入镜像内 dsh 应等于的版本号
#                           (不含 dsh-v 前缀, 如 0.1.2-rc.1)
# 环境变量:
#   DOCKER    docker 二进制, 默认 docker; podman 用户可 DOCKER=podman
#   其他依赖: curl, awk, sed; 需要空闲端口 3081 与 127.0.0.1:3082
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
cookie_jar="$(mktemp)"
cookie_relogin="$(mktemp)"
auth_cookie_jar="$(mktemp)"
trap '"$DOCKER" rm -f "$cid" "$auth_cid" >/dev/null 2>&1 || true; rm -f "$cookie_jar" "$cookie_relogin" "$auth_cookie_jar"' EXIT

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

# dsh web 启动后会把登录 URL(?token=...)打印到容器日志(经 dsh-web
# 镜像到容器日志); supervisor 会用它自举会话, 这里取 token 供交换
# 流程断言使用。容器提前退出时快速失败并带出日志。
running() { [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
token=""
for _ in $(seq 1 60); do
  token="$("$DOCKER" logs "$cid" 2>&1 | grep -o 'token=[A-Za-z0-9_-]*' | head -n1 | cut -d= -f2 || true)"
  [ -n "$token" ] && break
  running "$cid" || { "$DOCKER" logs --tail 30 "$cid" >&2 || true; die "container exited before printing a login token"; }
  sleep 2
done
[ -n "$token" ] || { "$DOCKER" logs --tail 30 "$cid" >&2 || true; die "no login token printed by dsh web"; }

# 栈引导顺序: dsh web 先行, dsh-web 换取会话 cookie 后才拉起 Caddy。
# token 出现后等 3081 可连通再继续, 消除引导竞态。
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:3081/ 2>/dev/null && break
  running "$cid" || { "$DOCKER" logs --tail 30 "$cid" >&2 || true; die "container exited before the proxy became ready"; }
  sleep 1
done

exchange="$(curl -sS -o /dev/null -w '%{http_code}' -c "$cookie_jar" \
  "http://127.0.0.1:3081/?token=$token")"
[ "$exchange" = "303" ] || die "token exchange returned $exchange, expected 303"

# 会话注入: 不带任何 cookie 的请求也拿到完整页面 —— dsh 的浏览器围栏
# 被 Caddy 侧自举的会话吸收, 3081 上不再有 401 流程, 鉴权只看 Caddy。
proxied_open="$(curl -sS http://127.0.0.1:3081/)"
[[ "$proxied_open" == *'<title>DeepSeek Harness</title>'* ]] \
  || die "proxied / without cookies does not serve the app (session injection broken)"
# 鉴权职责没有后退到 dsh: 3080 直连(绕过 Caddy)无 cookie 仍必须 401,
# 同网段容器/进程无法绕过代理直接使用。
direct_unauth="$("$DOCKER" exec "$cid" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/)"
[ "$direct_unauth" = "401" ] || die "direct dsh (3080) without cookie returned $direct_unauth, expected 401"
# 首页必须 no-store: 防止镜像升级后浏览器沿用旧前端。
curl -sS -o /dev/null -D - http://127.0.0.1:3081/ | grep -qi 'cache-control: no-store' \
  || die "GET / response lacks Cache-Control: no-store"

# 会话内页面: 标题与前端补丁。先取回整个 index 再做包含判断,
# 避免 curl | grep -q 的 SIGPIPE/静默失败。
index_html="$(curl -fsS -b "$cookie_jar" http://127.0.0.1:3081/)" \
  || die "GET / with session cookie failed"
[[ "$index_html" == *'<title>DeepSeek Harness</title>'* ]] \
  || die "served index.html does not contain the expected title"
[[ "$index_html" == *'dsh-container randomUUID polyfill'* ]] \
  || die "served index.html lacks the crypto.randomUUID polyfill"

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
"$DOCKER" exec "$cid" node --version | grep -Eq '^v[0-9]+\.'
"$DOCKER" exec "$cid" cargo --version | grep -Eq '^cargo [0-9]+\.'
"$DOCKER" exec "$cid" uv --version | grep -Eq '^uv [0-9]+\.'
"$DOCKER" exec "$cid" pnpm --version | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'
"$DOCKER" exec "$cid" podman --version | grep -Eq '^podman version [0-9]+\.'
"$DOCKER" exec "$cid" gh --version | grep -Eq '^gh version [0-9]+\.'

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
  test -w "$cargo_home"
  test -w "$home/.local/bin"
  mkdir -p "$cargo_home/registry/cache" "$cargo_home/registry/index" "$pnpm_home"
' || die "toolchain/user-layer layout check failed"

# 旧卷工具副本不得遮蔽镜像真二进制: 种入旧 uv 后 PATH 镜像优先仍解析到
# /usr/local/bin/uv(清理不进镜像, 手动步骤见 release notes)。
"$DOCKER" exec "$cid" sh -c 'home="$(getent passwd "$(id -u)" | cut -d: -f6)"; printf "#!/bin/sh\necho \"uv 0.0.1 (fake-old)\"\n" > "$home/.local/bin/uv" && chmod +x "$home/.local/bin/uv"'
"$DOCKER" exec "$cid" sh -c 'test "$(command -v uv)" = "/usr/local/bin/uv"' \
  || die "a stale volume uv copy shadows the image-provided uv"
"$DOCKER" exec "$cid" sh -c 'home="$(getent passwd "$(id -u)" | cut -d: -f6)"; rm -f "$home/.local/bin/uv"'
# Caddy 代理已在容器内运行(头改写链路)
"$DOCKER" exec "$cid" sh -c 'pgrep -x caddy >/dev/null' \
  || die "caddy process not found inside the container"
# dsh 必须解析到镜像内版本 (卷中旧 npm 副本若存在也不得遮蔽)。
"$DOCKER" exec "$cid" sh -c '[ "$(command -v dsh)" = "/usr/local/bin/dsh" ]' \
  || die "dsh does not resolve to the image-provided /usr/local/bin/dsh"
"$DOCKER" exec "$cid" cat /etc/dsh-container/provenance.json | grep -q '"image":"ghcr.io/niyueee/dsh-container"' \
  || die "image provenance stamp missing or invalid"
# 镜像拥有全部工具链后, provenance 首次能如实记录实际工具版本
"$DOCKER" exec "$cid" jq -e '.tools.node and .tools.pnpm and .tools.rust and .tools.uv' \
  /etc/dsh-container/provenance.json >/dev/null \
  || die "provenance tool versions missing"

# supervisor 安全细节: 凭证类文件仅运行时用户可读; 未配置 basic auth
# 的容器必须打印裸奔警告(本容器即无 auth)。
"$DOCKER" exec "$cid" sh -c \
  '[ "$(stat -c %a /tmp/dsh-caddy/session-cookie)" = "600" ] && [ "$(stat -c %a /tmp/dsh-caddy/Caddyfile)" = "600" ]' \
  || die "session-cookie/Caddyfile permissions are not 0600"
"$DOCKER" logs "$cid" 2>&1 | grep -F 'WARNING: the proxy listens on 0.0.0.0:3081 with NO authentication' \
  || die "no-auth proxy did not print the exposure warning"

# 特权 API(/api/settings/describe 属上游 PRIVILEGED_METHODS): 经代理
# 一律 200(会话由 Caddy 注入); 3080 直连无 cookie 必须 401 —— 同网段
# 容器无法绕过代理拿特权接口。
settings_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  http://127.0.0.1:3081/api/settings/describe -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$settings_code" = "200" ] || die "proxied /api/settings/describe returned $settings_code, expected 200"
direct_api="$("$DOCKER" exec "$cid" curl -s -o /dev/null -w '%{http_code}' -X POST \
  http://127.0.0.1:3080/api/settings/describe -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$direct_api" = "401" ] || die "direct dsh (3080) /api without cookie returned $direct_api, expected 401"

# 前端兼容补丁: 新 upstream dsh 以 /plugins/??<id>/client.js&rev=...
# 形式在首页注入 bundle URL, 提取 connection 的单包 URL 后验证补丁。
connection_bundle_url="$(grep -o '/plugins/??@deepseek-ai/dsh-client-connection/client.js&rev=[^" ]*' \
  <<<"$index_html" | head -n1 || true)"
[ -n "$connection_bundle_url" ] \
  || die "connection client bundle URL not found in served index"
connection_bundle="$(curl -fsS "http://127.0.0.1:3081${connection_bundle_url}")" \
  || die "fetching the connection client bundle failed"
[[ "$connection_bundle" == *'isLoopback: true, // dsh-container remote-proxy patch'* ]] \
  || die "served connection bundle lacks the isLoopback patch"
[[ "$connection_bundle" != *'isLoopback: pageLocation === void 0'* ]] \
  || die "old isLoopback gate still present in the served bundle"
[[ "$connection_bundle" != *'isLoopback: transport?.ownsHost === true'* ]] \
  || die "old isLoopback gate still present in the served bundle"

# 非回环 Host 头模拟远程浏览器: Caddy 改写后同样可用。注意 curl 在
# 覆盖 Host 头时不会按 jar 匹配发送 cookie, 因此这里显式携带会话
# cookie(真实远程浏览器按自己访问的 host 存取 cookie, 不受影响)。
session_cookie="$(awk -F'\t' 'NF>=7 {print $6 "=" $7}' "$cookie_jar" | tail -n1)"
[ -n "$session_cookie" ] || die "session cookie missing from the cookie jar"
index_alt="$(curl -fsS -H "Cookie: $session_cookie" -H 'Host: dsh.test' http://127.0.0.1:3081/)" \
  || die "GET / with Host: dsh.test failed"
[[ "$index_alt" == *'dsh-container randomUUID polyfill'* ]] \
  || die "Host: dsh.test index lacks the polyfill"
bundle_alt="$(curl -fsS -H 'Host: dsh.test' "http://127.0.0.1:3081${connection_bundle_url}")" \
  || die "fetching the connection bundle with Host: dsh.test failed"
[[ "$bundle_alt" == *'isLoopback: true, // dsh-container remote-proxy patch'* ]] \
  || die "Host: dsh.test bundle lacks the isLoopback patch"
"$DOCKER" exec "$cid" sh -c 'command -v dsh-client-patch >/dev/null' \
  || die "dsh-client-patch not installed"

# dsh web 守护/重启: dsh-restart 后由 dsh-web 重新拉起, 新进程会打印
# 新 token; 等新 token 出现后重新登录, 再验证页面与补丁仍然可用。
"$DOCKER" exec "$cid" dsh-restart || die "dsh-restart failed"
token2=""
exchange2=""
for _ in $(seq 1 90); do
  token2="$("$DOCKER" logs "$cid" 2>&1 | grep -o 'token=[A-Za-z0-9_-]*' | tail -n1 | cut -d= -f2 || true)"
  if [ -n "$token2" ] && [ "$token2" != "$token" ]; then
    exchange2="$(curl -sS -o /dev/null -w '%{http_code}' -c "$cookie_relogin" \
      "http://127.0.0.1:3081/?token=$token2" || true)"
    if [ "$exchange2" = "303" ]; then break; fi
  fi
  sleep 1
done
[ "$exchange2" = "303" ] \
  || die "re-login after dsh-restart failed (last exchange=${exchange2:-none})"
# 会话跨 dsh web 重启存活(签名密钥持久化在卷): 重启后无 cookie 的代理
# 请求必须仍是 200 —— supervisor 可能正带着新 cookie 重启 Caddy, 短重试。
survive=""
for _ in $(seq 1 15); do
  survive="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3081/ || true)"
  [ "$survive" = "200" ] && break
  sleep 1
done
[ "$survive" = "200" ] \
  || die "proxied / after dsh-restart returned $survive, expected 200 (session did not survive restart)"
# 信息性: 重启前的会话 cookie 是否仍被接受(不作为判定条件)。
old_cookie_code="$(curl -s -o /dev/null -w '%{http_code}' -b "$cookie_jar" http://127.0.0.1:3081/ || true)"
if [ "$old_cookie_code" != "200" ]; then
  echo "=== [smoke] note: pre-restart session cookie no longer accepted after restart (code=$old_cookie_code); re-login used" >&2
fi

index_restart="$(curl -fsS -b "$cookie_relogin" http://127.0.0.1:3081/)" \
  || die "GET / after restart failed"
[[ "$index_restart" == *'<title>DeepSeek Harness</title>'* ]] \
  || die "served index.html after restart lacks the expected title"
[[ "$index_restart" == *'dsh-container randomUUID polyfill'* ]] \
  || die "served index.html after restart lacks the polyfill"
bundle_restart_url="$(grep -o '/plugins/??@deepseek-ai/dsh-client-connection/client.js&rev=[^" ]*' \
  <<<"$index_restart" | head -n1 || true)"
[ -n "$bundle_restart_url" ] \
  || die "connection bundle URL not found in served index after restart"
bundle_restart="$(curl -fsS "http://127.0.0.1:3081${bundle_restart_url}")" \
  || die "fetching the connection bundle after restart failed"
[[ "$bundle_restart" == *'isLoopback: true, // dsh-container remote-proxy patch'* ]] \
  || die "connection bundle after restart lacks the isLoopback patch"
[[ "$bundle_restart" != *'isLoopback: pageLocation === void 0'* ]] \
  || die "old isLoopback gate reappeared after restart"

# basic auth 模式: 未带 basic 凭据 401; 带凭据后 token 换 cookie(303),
# 之后 root 与特权 API 均 200。
auth_cid="$("$DOCKER" run -d --rm --name dsh-smoke-auth -p 127.0.0.1:3082:3081 \
  -e DSH_HOME=/tmp/dsh-smoke-auth-home \
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
# 等 Caddy(basic auth)就绪: 未认证请求返回 401 即代表代理已监听。
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:3082/ 2>/dev/null && break
  running "$auth_cid" || { "$DOCKER" logs --tail 30 "$auth_cid" >&2 || true; die "basic-auth container exited before the proxy became ready"; }
  sleep 1
done
unauth="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3082/)"
[ "$unauth" = "401" ] || die "basic-auth proxy returned $unauth without credentials, expected 401"
auth_exchange="$(curl -s -o /dev/null -w '%{http_code}' -u smoke:smoke-pass \
  -c "$auth_cookie_jar" "http://127.0.0.1:3082/?token=$auth_token")"
[ "$auth_exchange" = "303" ] || die "basic-auth token exchange returned $auth_exchange, expected 303"
auth_root="$(curl -s -o /dev/null -w '%{http_code}' -u smoke:smoke-pass \
  -b "$auth_cookie_jar" http://127.0.0.1:3082/)"
[ "$auth_root" = "200" ] || die "basic-auth root with cookie returned $auth_root, expected 200"
auth_api="$(curl -s -o /dev/null -w '%{http_code}' -u smoke:smoke-pass \
  -b "$auth_cookie_jar" -X POST \
  http://127.0.0.1:3082/api/settings/describe -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[ "$auth_api" = "200" ] || die "basic-auth API with cookie returned $auth_api, expected 200"

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

echo "=== [smoke] PASS: all checks passed for $image"
