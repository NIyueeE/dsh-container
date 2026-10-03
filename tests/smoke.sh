#!/usr/bin/env bash
# dsh-container 镜像冒烟测试: 对给定镜像做端到端验证, 覆盖 token 交换、
# Caddy 头改写、会话注入、前端补丁、遥测默认关闭、工具链分层布局、内置
# 常用工具与容器内 podman 运行期环境、supervisor 重启与 basic auth 全链路。
# 由 .github/workflows/image.yml 与 release-prep.yml 共同调用; 本地可用
# `just test` 运行。
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
# 上游的索引入口有两个(dist 根 + 配置的 index path, 即 / 与 /index.html),
# 两个都必须禁缓存 —— 否则从 /index.html 进入的浏览器会缓存旧启动清单。
# /index.html 是索引入口这件事本身也在这里钉住(上游改为 404 时会失败, 提示
# 复核 dsh-web 的 @index 规则是否还需要第二个路径)。
curl -sS -o /dev/null -D - http://127.0.0.1:3081/ | grep -qi 'cache-control: no-store' \
  || die "GET / response lacks Cache-Control: no-store"
curl -sS -o /dev/null -D - http://127.0.0.1:3081/index.html | grep -qi 'cache-control: no-store' \
  || die "GET /index.html response lacks Cache-Control: no-store (index entry caching not covered)"

# 会话内页面: 标题与前端补丁。先取回整个 index 再做包含判断,
# 避免 curl | grep -q 的 SIGPIPE/静默失败。
index_html="$(curl -fsS -b "$cookie_jar" http://127.0.0.1:3081/)" \
  || die "GET / with session cookie failed"
[[ "$index_html" == *'<title>DeepSeek Harness</title>'* ]] \
  || die "served index.html does not contain the expected title"

# /assets/* 是 Vite 构建的内容哈希产物, 但 dsh 自己不给这棵树发任何缓存头
# (实测无 Cache-Control/ETag/Last-Modified) —— 少了 Caddy 补的 immutable, 浏览器
# 每次导航都要重下约 475 KiB 的 shell 资源。这里用索引里真正引用的第一个 assets
# JS 条目验证: 路径可达(200) 且响应带 immutable 头。
asset_path="$(printf '%s' "$index_html" | grep -o 'assets/[A-Za-z0-9._-]\+\.js' | head -n1)"
[ -n "$asset_path" ] || die "served index references no hashed /assets JS entry"
asset_status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:3081/$asset_path")"
[ "$asset_status" = "200" ] || die "GET /$asset_path returned $asset_status, expected 200"
curl -sS -o /dev/null -D - "http://127.0.0.1:3081/$asset_path" \
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
"$DOCKER" exec "$cid" sh -c '
  for t in rg fd patch zip less vi nano ssh rsync wget tree htop sqlite3 tmux crun; do
    command -v "$t" >/dev/null || { echo "missing built-in tool: $t" >&2; exit 1; }
  done
  python3 --version
  fd --version
  crun --version
  git lfs version
' || die "built-in tool check failed"

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
# Caddy 代理已在容器内运行(头改写链路)
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

# supervisor 安全细节: 凭证类文件仅运行时用户可读; 未配置 basic auth
# 的容器必须打印裸奔警告(本容器即无 auth)。
"$DOCKER" exec "$cid" sh -c \
  '[ "$(stat -c %a /tmp/dsh-caddy/session-cookie)" = "600" ] && [ "$(stat -c %a /tmp/dsh-caddy/Caddyfile)" = "600" ]' \
  || die "session-cookie/Caddyfile permissions are not 0600"
# 会话 cookie 由容器适配插件在 dsh 进程内自举(替代旧的 dsh-web token 交换):
# 日志必须出现插件的自举记录。插件走 ctx.logger, 但本 profile 没有任何 console
# exporter, 因此插件自己注册了一个"只导出本插件日志"的 exporter(见 index.js) ——
# 这一行同时钉住"日志确实落到了容器日志"。
"$DOCKER" logs "$cid" 2>&1 | grep -E 'dsh-container-adapt.*session cookie (minted|reusing)' \
  || die "container-adapt plugin did not bootstrap the session cookie (or its log line is not visible)"
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

# 设置 > 打开配置文件按钮隐藏: 容器无桌面, 上游 openSettingsDocument 无
# headless 兜底(会 spawn 原生文本编辑器命令扑空)—— 插件包 settingsController
# 实例的 describe(旧 tag 上再翻 provider 的 documentPath), 上游 describe 即
# 返回 hasDocument:false, 浏览器侧 SettingsDocumentAction 按上游自身逻辑
# (status !== 'ready' → 不渲染)让按钮消失, 不引入任何浏览器侧代码。经 3081
# 的请求由 Caddy 注入会话 cookie。
settings_body="$(curl -s -X POST http://127.0.0.1:3081/api/settings/describe \
  -H 'content-type: application/json' \
  --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}')"
[[ "$settings_body" == *'"hasDocument":false'* ]] \
  || die "settings describe did not report hasDocument:false (button-hide fuse broken): $settings_body"
# 旧下载入口已删除: /download/settings.yaml 只应落到前端 SPA fallback
# (HTML 页面), 任何 content-disposition: attachment 响应都意味着端点回归。
dl_gone="$(curl -s -D - -o /dev/null http://127.0.0.1:3081/download/settings.yaml)"
printf '%s' "$dl_gone" | grep -qi 'content-disposition: attachment' \
  && die "removed download endpoint still serves /download/settings.yaml"

# 传输层声明: 容器适配插件向上游的结构化索引注入表推一行
# __DSH_TRANSPORT__={ownsHost:true}(替代旧的构建产物字符串补丁)。上游把它渲染成
# <head> 里的内联脚本 —— 先于 type="module" 的 bundle 执行, connection 插件的
# isLoopback 才读得到(上游唯一消费点)。位置不必紧贴 <head>(上游自己的 base 与
# 其它 global 行也在那一段, 行的先后由表顺序决定)。
transport_injection='<script>globalThis["__DSH_TRANSPORT__"] = {"ownsHost":true}</script>'
[[ "$index_html" == *"$transport_injection"* ]] \
  || die "served index lacks the __DSH_TRANSPORT__ ownsHost injection"
[[ "${index_html%%</head>*}" == *"$transport_injection"* ]] \
  || die "the transport injection is not inside <head> (it would run after the module scripts)"
# 非回环 Host 头模拟远程浏览器: 注入与 Host 无关(代理改写后同样可用)。
index_alt_host="$(curl -fsS -H 'Host: dsh.test' http://127.0.0.1:3081/)" \
  || die "GET / with Host: dsh.test failed"
[[ "${index_alt_host%%</head>*}" == *"$transport_injection"* ]] \
  || die "Host: dsh.test index lacks the transport injection in <head>"
# 容器适配插件(container/plugin/)必须随镜像安装: 会话 cookie 自举、传输层注入、
# 抽图路由与三个构建期后处理脚本都在插件包内。
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
combo_bytes="$(curl -fsS --compressed -o "$combo_body" -w '%{size_download}' "http://127.0.0.1:3081${combo_url}")" \
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
  asset_headers="$(curl -fsS -D - -o /dev/null "http://127.0.0.1:3081${asset_path}")" \
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

# dsh web 守护/重启: dsh-restart 后由 dsh-web 重新拉起, 新进程会打印
# 新 token; 等新 token 出现后重新登录, 再验证页面与补丁仍然可用。
# cookie 文件是状态(内容 = 当前有效 cookie), 不是事件: 复用旧 cookie 时插件
# 不写盘, dsh-web 也不等待写入(只在文件缺失时等待、只在内容变化时重建 Caddy
# 配置)。所以这里只断言可见行为, 不 grep 日志文本、不等 mtime。
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
# 重启后 Caddy 注入的 cookie 仍被 dsh 接受: 特权方法经代理必须 200
# (dsh-web 若没把(可能已轮换的)新 cookie 收敛进 Caddy, 这里会拿到 401)。
# 插件是复用还是重新铸造 cookie 都合法 —— 不作为判定条件。
settings_restart=""
for _ in $(seq 1 15); do
  settings_restart="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    http://127.0.0.1:3081/api/settings/describe -H 'content-type: application/json' \
    --data '{"type":"client-request","rpcId":"1","method":"settings/describe","payload":{"args":{}}}' || true)"
  [ "$settings_restart" = "200" ] && break
  sleep 1
done
[ "$settings_restart" = "200" ] \
  || die "proxied /api/settings/describe after dsh-restart returned $settings_restart, expected 200"
# 信息性: 重启前的会话 cookie 是否仍被接受(不作为判定条件)。
old_cookie_code="$(curl -s -o /dev/null -w '%{http_code}' -b "$cookie_jar" http://127.0.0.1:3081/ || true)"
if [ "$old_cookie_code" != "200" ]; then
  echo "=== [smoke] note: pre-restart session cookie no longer accepted after restart (code=$old_cookie_code); re-login used" >&2
fi

index_restart="$(curl -fsS -b "$cookie_relogin" http://127.0.0.1:3081/)" \
  || die "GET / after restart failed"
[[ "$index_restart" == *'<title>DeepSeek Harness</title>'* ]] \
  || die "served index.html after restart lacks the expected title"
[[ "${index_restart%%</head>*}" == *"$transport_injection"* ]] \
  || die "transport injection missing from the index <head> after dsh web restart"

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

# issue #12 回归(同容器重启路径): cookie 文件在 /tmp 里跨 `docker restart`
# 存活。旧实现把"文件被写了一次(mtime 前进)"当成就绪信号, 而复用该 cookie
# 时插件不写盘 → dsh-web 空等 120s 后 exit 1, 在 restart 策略下变成每约
# 2 分钟一次的崩溃循环。这里真等过那个 120s 窗口, 确认容器仍在运行且代理
# 可用; 插件复用还是轮换 cookie 都合法。
"$DOCKER" restart "$cid" >/dev/null || die "docker restart failed"
restart_root=""
for _ in $(seq 1 60); do
  restart_root="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3081/ || true)"
  [ "$restart_root" = "200" ] && break
  running "$cid" || { "$DOCKER" logs --tail 40 "$cid" >&2 || true; die "container exited while coming back from docker restart"; }
  sleep 1
done
[ "$restart_root" = "200" ] \
  || die "proxied / after docker restart returned $restart_root, expected 200"
echo "=== [smoke] waiting 130s to confirm the container survives the post-restart window (issue #12)" >&2
sleep 130
running "$cid" \
  || { "$DOCKER" logs --tail 40 "$cid" >&2 || true; die "container exited within 130s of docker restart (issue #12 regression)"; }
restart_root_late="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3081/ || true)"
[ "$restart_root_late" = "200" ] \
  || die "proxied / 130s after docker restart returned $restart_root_late, expected 200"

echo "=== [smoke] PASS: all checks passed for $image"
