#!/usr/bin/env bash
# dsh web 守护脚本(容器内整个服务栈的监督者):
#   1. 启动 `dsh web`(输出写入日志文件并 tail 镜像到 stdout, 容器日志仍可见),
#      退出/崩溃后自动重新拉起; 配合 `dsh-restart` 可在容器内部重启 dsh web。
#      启动命令挂载镜像自带的容器适配插件 overlay(--patch, launcher flag,
#      必须位于 `web` 之前): 插件把 launch token 写到 /tmp/dsh-caddy/launch-token,
#      Caddy 用它把浏览器首次访问 302 到 /?token=...; 浏览器自己从 dsh 拿到
#      HttpOnly/SameSite=Strict 会话 cookie —— 容器不注入 cookie, 也不改写
#      Host/Origin。
#   2. 把插件写出的 launch token 当状态读取: 文件存在且非空 ⇔ 插件当前持有一个
#      可用 token; 本脚本只在文件缺失时等待, 之后每轮比较内容, 变了才重建
#      Caddyfile 并 `caddy reload`(热更新, 旧浏览器 cookie 仍有效, 因为 dsh 的
#      签名密钥持久化在数据卷)。没有 mtime 握手; 这个路径是本脚本与插件的
#      共享契约(插件侧 Config.runtimeDir 默认值相同; 覆写插件配置就必须同步
#      这里的 RUNTIME_DIR)。
#   3. 启动 Caddy 反代监听 0.0.0.0:3081: 保留浏览器 Host/Origin 原样转发到
#      127.0.0.1:$DSH_WEB_PORT; 只接受 loopback 和 --trusted-host 授权的外部
#      authority(Host 允许列表, 防 DNS rebinding); 浏览器没有 dsh 会话 cookie 时
#      302 到 /?token=... 完成登录; basic auth 仍然可选(DSH_PROXY_USER +
#      DSH_PROXY_PASSWORD 必须成对设置), 但 /api/remote.mux 的 WebSocket 升级
#      由 dsh 的 SameSite=Strict cookie 认证, 不要求 basic auth(浏览器不保证给
#      WS 带 Authorization)。另外补两条缓存策略: 两个索引入口(/ 与
#      /index.html)no-store(动态启动清单), 内容哈希的 /assets/* immutable
#      (dsh 自己不发缓存头, 否则每次导航重下约 475 KiB); 运行期崩溃自动重启
#      (配置错误 fail-fast)。
#   4. 外部 authority/公告地址通过环境变量配置:
#      DSH_PUBLIC_URL  浏览器实际访问的根 URL(默认 http://127.0.0.1:3081/),
#                      传给 dsh --public-url, 只用于公告/agent 上下文, 不授予信任;
#      DSH_TRUSTED_HOST 逗号分隔的额外 authority(host 或 host:port), 传给
#                      dsh --trusted-host; 不设时自动从 DSH_PUBLIC_URL 的 host
#                      派生(远程部署通常只需要设置 DSH_PUBLIC_URL 一个变量)。
#      两者都会进入 Caddy 的 Host 允许列表; 不在列表里的 Host 直接 403。
# 附加参数会原样透传给 dsh web, 例如 --port 8080; 容器内默认追加
# --no-open(无浏览器环境), 用户显式传入时不重复。
set -euo pipefail

# 独立执行时也尽量还原 HOME(与 entrypoint 行为一致)。
if ! HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"; then
  echo "[dsh-web] cannot resolve HOME for uid $(id -u)" >&2
  exit 1
fi
if [ -z "$HOME" ]; then
  echo "[dsh-web] empty HOME for uid $(id -u)" >&2
  exit 1
fi
export HOME

# PATH 镜像优先: dsh 必须解析到镜像内的 /usr/local/bin/dsh, 而不是旧数据卷
# 中可能残留的副本; 再拼接用户层自装工具目录(pnpm 全局 bin 在 $PNPM_HOME/bin,
# 与 entrypoint.sh 及 Containerfile 的 ENV PATH 是同一条链路, 必须同步)。
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:${PNPM_HOME:-$HOME/.local/share/pnpm}/bin:$PATH"

# 内部端口: entrypoint 解析 --port 后经 DSH_WEB_PORT 传入(默认 3080)。
# 独立执行(不经 entrypoint)时自身也解析 --port <N>/--port=<N> —— 否则
# dsh web 监听 N 而 Caddy 仍转发到默认端口, 每个请求静默 502。
args_port=""
expect_port=0
for a in "$@"; do
  if [ "$expect_port" = 1 ]; then
    args_port="$a"
    expect_port=0
    continue
  fi
  case "$a" in
    --port) expect_port=1 ;;
    --port=*) args_port="${a#--port=}" ;;
  esac
done
WEB_PORT="${DSH_WEB_PORT:-${args_port:-3080}}"
case "$WEB_PORT" in
  ''|*[!0-9]*) echo "[dsh-web] invalid DSH_WEB_PORT: '$WEB_PORT' (must be a number)" >&2; exit 1 ;;
esac

# 容器/调用方的附加参数(透传给 dsh web)。注意: 函数内的 "$@" 是函数自己的
# 参数而非脚本的, 必须先捕获到数组, 否则 --port 等透传参数会静默丢失。
WEB_ARGS=()
case " $* " in
  *" --no-open "*) WEB_ARGS=("$@") ;;
  *) WEB_ARGS=("$@" "--no-open") ;;
esac

# 外部公告地址: 只影响 dsh 打印/公告的 URL 与 agent 运行时上下文, 不授予信任。
# 远程部署(公网/LAN)应设成浏览器实际打开的根 URL; 默认值对应示例的宿主 3081。
DSH_PUBLIC_URL="${DSH_PUBLIC_URL:-http://127.0.0.1:3081/}"
case "$DSH_PUBLIC_URL" in
  http://*|https://*) ;;
  *) echo "[dsh-web] invalid DSH_PUBLIC_URL: '$DSH_PUBLIC_URL' (must start with http:// or https://)" >&2; exit 1 ;;
esac

# 用户是否自己传了 --public-url(避免重复); DSH_PUBLIC_URL 仍可作为 trusted-host 来源。
public_url_arg=0
for a in "$@"; do
  case "$a" in
    --public-url|--public-url=*) public_url_arg=1 ;;
  esac
done

# 最低支持 dsh 0.2.1: --public-url 是必备 flag, 不需要 help 探测/降级。
# authority 解析: 只接受 host[:port] 或 [IPv6][:port]; 拒绝空白/斜杠/注入字符。
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

TRUSTED_HOSTS=()
CADDY_HOSTS=(127.0.0.1 localhost)
declare -A trusted_seen=()
declare -A caddy_seen=([127.0.0.1]=1 [localhost]=1)

add_caddy_host() {
  local host="$1"
  [ -z "$host" ] && return 0
  if [ -n "${caddy_seen[$host]:-}" ]; then return 0; fi
  caddy_seen[$host]=1
  CADDY_HOSTS+=("$host")
}

add_trusted_host() {
  local entry host
  entry="$(trim "$1")"
  [ -z "$entry" ] && return 0
  if [[ $entry =~ ^(\[[0-9A-Fa-f:]+\])(:[0-9]+)?$ ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ $entry =~ ^([A-Za-z0-9._-]+)(:[0-9]+)?$ ]]; then
    host="${BASH_REMATCH[1]}"
  else
    echo "[dsh-web] invalid authority in DSH_TRUSTED_HOST/DSH_PUBLIC_URL: '$entry'" >&2
    return 1
  fi
  if [ -z "${trusted_seen[$entry]:-}" ]; then
    trusted_seen[$entry]=1
    TRUSTED_HOSTS+=("$entry")
  fi
  add_caddy_host "$host"
}

# DSH_TRUSTED_HOST: 逗号分隔; 原样传给 dsh(host:port 精确匹配, 无端口匹配任意端口)。
if [ -n "${DSH_TRUSTED_HOST:-}" ]; then
  IFS=',' read -r -a trusted_entries <<< "$DSH_TRUSTED_HOST"
  for entry in "${trusted_entries[@]}"; do
    add_trusted_host "$entry" || exit 1
  done
fi

# 从 DSH_PUBLIC_URL 派生 authority: 远程部署通常只设这一个变量。
# 只取 host(去掉端口): 浏览器对默认端口会省略 Host 里的端口, 带端口的
# trusted entry 反而匹配不上; dsh 的无端口 entry 匹配任意端口, 足够安全。
public_authority="${DSH_PUBLIC_URL#*://}"
public_authority="${public_authority%%/*}"
public_authority="${public_authority##*@}"
if [[ $public_authority =~ ^(\[[0-9A-Fa-f:]+\])(:[0-9]+)?$ ]]; then
  public_authority="${BASH_REMATCH[1]}"
elif [[ $public_authority =~ ^([A-Za-z0-9._-]+)(:[0-9]+)?$ ]]; then
  public_authority="${BASH_REMATCH[1]}"
fi
add_trusted_host "$public_authority" || exit 1

cd "$HOME"

RUNTIME_DIR=/tmp/dsh-caddy
CADDYFILE="$RUNTIME_DIR/Caddyfile"
TOKEN_FILE="$RUNTIME_DIR/launch-token"
LOG=/tmp/dsh-web.log

PIDFILE=/tmp/dsh-web.pid
CHILD_PID=""
CADDY_PID=""
STOPPING=0

# caddy 存活检查: kill -0 对僵尸进程也返回成功(caddy 的父进程是本脚本,
# 会回收子进程), 必须通过 /proc 状态排除 Z。
caddy_alive() {
  local st
  st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  st="${st#*) }"
  case "$st" in
    Z*) return 1 ;;
  esac
  return 0
}

# SC2317: cleanup() 只经下面的 trap 调用, shellcheck 静态看是"不可达", 属误报。
# shellcheck disable=SC2317
cleanup() {
  STOPPING=1
  if [ -n "$CADDY_PID" ]; then
    kill "$CADDY_PID" 2>/dev/null || true
  fi
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null || true
  fi
  if [ -n "$CHILD_PID" ]; then
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}
trap cleanup TERM INT EXIT

# --- dsh web 启动 -------------------------------------------------------------
# 输出重定向到日志文件再 tail 镜像到 stdout: 容器日志仍能看到 dsh web 的
# 全部输出(含一次性登录 token 与报错)。启动命令用 launcher 根 flag 组合
# `--patch <overlay> --profile web`(注意: `web` 别名会拒绝父级 --patch,
# 见上游 args.ts rejectParentOptions —— 必须用 --profile web 形式)。
# --public-url / --trusted-host 只在 web profile 上有效, 放在 --profile web 之后。
start_dsh_web() {
  : > "$LOG"
  rm -f "$TOKEN_FILE"
  local -a extra=()
  if [ "$public_url_arg" = 0 ]; then
    extra+=(--public-url "$DSH_PUBLIC_URL")
  fi
  local h
  for h in "${TRUSTED_HOSTS[@]}"; do
    extra+=(--trusted-host "$h")
  done
  dsh --patch /opt/dsh-container-plugin/overlay.yml --profile web "${extra[@]}" "${WEB_ARGS[@]}" >>"$LOG" 2>&1 &
  CHILD_PID=$!
  echo "$CHILD_PID" > "$PIDFILE"
  echo "[dsh-web] dsh web started (pid $CHILD_PID)" >&2
  tail -f --pid="$CHILD_PID" "$LOG" &
}

# --- launch token(状态文件, 非事件) ------------------------------------------
# 由插件在 dsh 进程内写出; 本脚本把 TOKEN_FILE 当状态读取: 存在且非空 ⇔
# 当前进程有一个可用 token。文件缺失 → 有界等待; 内容变化 → 重建 Caddyfile
# 并热更新 Caddy。启动前会删掉旧 token, 所以每次 dsh 重启都必然等新文件。
wait_for_token() {
  for _ in $(seq 1 120); do
    if [ -s "$TOKEN_FILE" ]; then
      echo "[dsh-web] launch token ready (written by the container-adapt plugin)" >&2
      return 0
    fi
    if ! kill -0 "$CHILD_PID" 2>/dev/null; then
      echo "[dsh-web] dsh web exited before the launch token appeared; last log lines:" >&2
      tail -n 20 "$LOG" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "[dsh-web] no launch token from the container-adapt plugin within 120s" >&2
  return 1
}

# dsh 端口就绪门: 容器重启时 token 文件可能已存在, 不先等 dsh 监听就拉起
# Caddy, 会让反代在 dsh 起来之前对用户返回 502。--noproxy 保证容器里配置了
# HTTP(S)_PROXY 时这些内部探针仍然直连回环(见 network-proxy 文档)。
wait_for_dsh_port() {
  for _ in $(seq 1 120); do
    if curl -s --noproxy '*' --max-time 2 -o /dev/null "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$CHILD_PID" 2>/dev/null; then
      echo "[dsh-web] dsh web exited before listening on 127.0.0.1:${WEB_PORT}; last log lines:" >&2
      tail -n 20 "$LOG" >&2 || true
      return 1
    fi
    sleep 0.5
  done
  echo "[dsh-web] dsh web did not accept connections on 127.0.0.1:${WEB_PORT} within 60s" >&2
  return 1
}

# --- Caddyfile 生成 -----------------------------------------------------------
# 关键顺序(route 内按书写顺序执行):
#   1. Host 允许列表 403 —— 必须早于 token 重定向, 否则任意 Host 都能拿到
#      Location 里的 token; dsh 的 index token 交换本身不做 Host 围栏, 所以
#      这一步是代理的职责。
#   2. basic auth(若配置), 但排除 WebSocket 路径: 浏览器不保证给 WS 升级带
#      Authorization, 而 WS 已经被 dsh 的 SameSite=Strict cookie 认证。
#   3. 索引 no-store / assets immutable。
#   4. 无 dsh 会话 cookie 的 GET / 或 /index.html → 302 到 /?token=...; token
#      来自插件的状态文件, 只存在于 0600 Caddyfile 与浏览器地址栏。
#   5. reverse_proxy 原样转发 Host/Origin; dsh 的围栏用 --trusted-host 授权。
generate_caddyfile() {
  local token token_ok=0
  token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
  case "$token" in
    ''|*[!A-Za-z0-9_-]*) token_ok=1 ;;
  esac
  if [ "$token_ok" = 1 ]; then
    echo "[dsh-web] invalid or empty launch token in $TOKEN_FILE" >&2
    return 1
  fi
  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
  # Caddyfile 含 token 与 bcrypt 哈希; 先收紧 umask, 避免 cat 创建时出现 0644 窗口。
  umask 077
  local caddy_hosts="${CADDY_HOSTS[*]}"
  # 缩进用 tab(caddy fmt 规范), 避免启动时 "Caddyfile input is not formatted" 警告。
  cat > "$CADDYFILE" <<EOF
{
	admin 127.0.0.1:2019
	auto_https off
}
:3081 {
	route {
		# 只接受 loopback + 显式授权的 authority; 其余 Host 直接 403。
		@badHost not host ${caddy_hosts}
		respond @badHost 403

		# basic auth 可选; WebSocket 由 dsh 的 SameSite=Strict cookie 认证。
		@needsAuth not path /api/remote.mux /api/events.mux
EOF
  if [ -n "${DSH_PROXY_USER:-}" ] || [ -n "${DSH_PROXY_PASSWORD:-}" ]; then
    # 只设置一个变量时 fail closed: 静默跳过 basic auth 会让用户以为已启用认证。
    if [ -z "${DSH_PROXY_USER:-}" ] || [ -z "${DSH_PROXY_PASSWORD:-}" ]; then
      echo "[dsh-web] DSH_PROXY_USER and DSH_PROXY_PASSWORD must be set together (refusing to start without auth)" >&2
      return 1
    fi
    case "$DSH_PROXY_USER" in
      *[!A-Za-z0-9_.@-]*) echo "[dsh-web] invalid DSH_PROXY_USER: '$DSH_PROXY_USER'" >&2; return 1 ;;
    esac
    # 通过 stdin 哈希, 避免密码出现在 caddy hash-password 的进程 argv 里。
    # caddy 从 stdin 逐行读取并去除末尾换行, 因此 printf 需要补一个 \n。
    # 发行版 caddy 2.6 的 Caddyfile 指令是 basicauth(2.7 起才叫 basic_auth);
    # bcrypt 哈希以 $ 开头即 Modular Crypt Format, 直接写原样, 无需 base64/转义。
    local hash
    if ! hash="$(printf '%s\n' "$DSH_PROXY_PASSWORD" | caddy hash-password 2>/dev/null)"; then
      echo "[dsh-web] failed to hash DSH_PROXY_PASSWORD" >&2
      return 1
    fi
    cat >> "$CADDYFILE" <<EOF
		basicauth @needsAuth {
			$DSH_PROXY_USER $hash
		}
EOF
  fi
  cat >> "$CADDYFILE" <<EOF

		# index.html 是动态启动清单(内联 bundle URL 与 rev): 必须禁缓存。
		@index path / /index.html
		header @index Cache-Control "no-store"
		# /assets/* 是 Vite 构建的内容哈希产物; dsh 自己不发缓存头。
		@assets path /assets/*
		header @assets Cache-Control "public, max-age=31536000, immutable"

		# 浏览器还没有 dsh 会话 cookie 时, 用插件写出的 launch token 完成
		# 首次登录; dsh 在 303 里 Set-Cookie, 之后浏览器自己携带。
		@needsLogin {
			method GET
			path / /index.html
			not query token=*
			not header_regexp Cookie "(^|;[[:space:]]*)dsh-auth-[A-Za-z0-9_-]+="
		}
		header @needsLogin Cache-Control "no-store"
		header @needsLogin Referrer-Policy "no-referrer"
		redir @needsLogin "/?token=${token}" 302

		reverse_proxy 127.0.0.1:${WEB_PORT}
	}
}
EOF
  # 文件含 launch token 与 bcrypt 哈希; 仅运行时用户可读。
  chmod 600 "$CADDYFILE"
}

# --- Caddy 启动/重启/热更新 ---------------------------------------------------
# 在最多约 5s 内等待代理端口可响应, 进程中途退出或始终无响应均 fail-fast
# (配置/端口错误不静默降级)。失败时不要把 Caddyfile 打到日志: 里面有 token。
start_caddy() {
  if [ -z "${DSH_PROXY_USER:-}" ] && [ -z "${DSH_PROXY_PASSWORD:-}" ]; then
    echo "[dsh-web] WARNING: the proxy listens on 0.0.0.0:3081 with NO authentication — set DSH_PROXY_USER + DSH_PROXY_PASSWORD before any non-loopback exposure (docs/security.md)" >&2
  fi
  caddy run --config "$CADDYFILE" --adapter caddyfile &
  CADDY_PID=$!
  local ready=0
  for _ in $(seq 1 20); do
    if ! caddy_alive "$CADDY_PID"; then
      echo "[dsh-web] caddy failed to start; inspect $CADDYFILE inside the container (not printed: it contains the launch token)" >&2
      return 1
    fi
    if curl -s --noproxy '*' --max-time 2 -o /dev/null "http://127.0.0.1:3081/" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.25
  done
  if [ "$ready" != "1" ]; then
    echo "[dsh-web] caddy did not become ready on 127.0.0.1:3081" >&2
    return 1
  fi
}

restart_caddy() {
  if [ -n "$CADDY_PID" ]; then
    kill "$CADDY_PID" 2>/dev/null || true
    wait "$CADDY_PID" 2>/dev/null || true
    CADDY_PID=""
  fi
  start_caddy
}

# token 轮换只改 Caddyfile 的一个 Location; caddy reload 热更新, 不丢现有连接。
# admin 只监听容器内 127.0.0.1:2019, 不对外暴露。reload 失败(例如旧进程还是
# admin off)则回退到重启, 由新配置接管。
reload_caddy() {
  if caddy reload --config "$CADDYFILE" --adapter caddyfile --address 127.0.0.1:2019 >>"$LOG" 2>&1; then
    echo "[dsh-web] caddy reloaded with the new launch token" >&2
    return 0
  fi
  echo "[dsh-web] caddy reload failed; restarting caddy" >&2
  restart_caddy
}

# --- 栈引导: dsh web → launch token → Caddy ----------------------------------
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
# 升级清理: 旧版本把 cookie 写在这里; 新模型不再使用它。
rm -f "$RUNTIME_DIR/session-cookie"
start_dsh_web
if ! wait_for_token; then
  echo "[dsh-web] launch token bootstrap failed; refusing to serve" >&2
  exit 1
fi
if ! wait_for_dsh_port; then
  echo "[dsh-web] dsh web is not accepting connections; refusing to serve" >&2
  exit 1
fi
generate_caddyfile
if ! start_caddy; then
  exit 1
fi
echo "[dsh-web] caddy started (pid $CADDY_PID); stack ready on 0.0.0.0:3081 -> 127.0.0.1:${WEB_PORT}" >&2

last_token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"

# --- 监督循环 -------------------------------------------------------------------
# 单线程轮询(2s): dsh web 退出则重启; launch token 文件缺失则等插件产出(有界,
# 等不到即退出交给编排层 —— 不静默降级); token 变化(新进程)才重建 Caddyfile
# 并 caddy reload —— 旧浏览器 cookie 仍然有效, 现有会话不中断。caddy 崩溃则重启。
while [ "$STOPPING" = "0" ]; do
  if ! kill -0 "$CHILD_PID" 2>/dev/null; then
    local_status=0
    set +e
    wait "$CHILD_PID" 2>/dev/null
    local_status=$?
    set -e
    CHILD_PID=""
    if [ "$STOPPING" = "1" ]; then
      break
    fi
    echo "[dsh-web] dsh web exited (status $local_status); restarting in 2s" >&2
    sleep 2
    start_dsh_web
    if ! wait_for_token; then
      echo "[dsh-web] launch token bootstrap failed after dsh web restart; giving up" >&2
      exit 1
    fi
    if ! wait_for_dsh_port; then
      echo "[dsh-web] dsh web is not accepting connections after restart; giving up" >&2
      exit 1
    fi
    generate_caddyfile || exit 1
    reload_caddy || exit 1
    last_token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
  fi
  if [ ! -s "$TOKEN_FILE" ]; then
    if ! wait_for_token; then
      echo "[dsh-web] launch token bootstrap failed after dsh web restart; giving up" >&2
      exit 1
    fi
  fi
  new_token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
  if [ -n "$new_token" ] && [ "$new_token" != "$last_token" ]; then
    echo "[dsh-web] launch token changed; regenerating caddy config" >&2
    generate_caddyfile || exit 1
    reload_caddy || exit 1
    last_token="$new_token"
  fi
  if [ -n "$CADDY_PID" ] && ! caddy_alive "$CADDY_PID"; then
    echo "[dsh-web] caddy exited; restarting" >&2
    restart_caddy || exit 1
  fi
  sleep 2
done

exit 0
