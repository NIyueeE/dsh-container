#!/usr/bin/env bash
# dsh web 守护脚本(容器内整个服务栈的监督者):
#   1. 启动 `dsh web`(输出写入日志文件并 tail 镜像到 stdout, 容器日志仍可见),
#      退出/崩溃后自动重新拉起; 配合 `dsh-restart` 可在容器内部重启 dsh web。
#   2. 会话自举(鉴权职责完全落在 Caddy, 浏览器/用户无需接触 token):
#      dsh web 每次启动会打印一次性 `?token=...` 登录 URL, 本脚本用它向
#      127.0.0.1:$DSH_WEB_PORT 换取会话 cookie 并存入 /tmp/dsh-caddy/,
#      随后生成的 Caddyfile 把该 cookie 注入所有代理请求。dsh 的签名密钥
#      持久化在数据卷凭据库中, cookie 默认 30 天有效、跨进程/跨容器重启有效
#      —— 已有有效 cookie 时直接复用, 不重复换取。dsh 自身的浏览器围栏
#      (3080 直连无 cookie 仍 401)原样保留, 3081 上的鉴权由 Caddy 承担
#      (basic auth / 网络暴露面)。
#   3. 启动 Caddy 反代监听 0.0.0.0:3081: 把 Host/Origin 改写为回环后转发到
#      127.0.0.1:$DSH_WEB_PORT, 对 UI 资源做 gzip 压缩, 并注入会话 cookie;
#      运行期崩溃自动重启(配置错误 fail-fast)。DSH_PROXY_USER +
#      DSH_PROXY_PASSWORD 必须成对设置以启用 basic auth, 只设置一个直接退出。
# 附加参数会原样透传给 dsh web, 例如 --port 8080。dsh web 自身不打开浏览器
# (也没有 --no-open 这个 flag), 无需追加参数。
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
# 中可能残留的副本; 再拼接用户层自装工具目录。
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# 内部端口: entrypoint 解析 --port 后经 DSH_WEB_PORT 传入(默认 3080)。
WEB_PORT="${DSH_WEB_PORT:-3080}"
case "$WEB_PORT" in
  ''|*[!0-9]*) echo "[dsh-web] invalid DSH_WEB_PORT: '$WEB_PORT' (must be a number)" >&2; exit 1 ;;
esac

# 容器/调用方的附加参数(透传给 dsh web)。注意: 函数内的 "$@" 是函数自己的
# 参数而非脚本的, 必须先捕获到数组, 否则 --port 等透传参数会静默丢失。
WEB_ARGS=()
WEB_ARGS=("$@")

cd "$HOME"

RUNTIME_DIR=/tmp/dsh-caddy
CADDYFILE="$RUNTIME_DIR/Caddyfile"
COOKIE_FILE="$RUNTIME_DIR/session-cookie"
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
# 全部输出(含一次性登录 token 与报错), 同时本脚本可以从日志提取 token。
start_dsh_web() {
  : > "$LOG"
  # 每次启动前重打前端兼容补丁(幂等, 已打过则跳过): 构建产物在系统层
  # /opt/deepseek-harness, 镜像构建时已打, 运行时再打一次兜底。
  if command -v dsh-client-patch >/dev/null 2>&1; then
    dsh-client-patch || echo "[dsh-web] dsh-client-patch failed; continuing" >&2
  fi
  dsh web "${WEB_ARGS[@]}" >>"$LOG" 2>&1 &
  CHILD_PID=$!
  echo "$CHILD_PID" > "$PIDFILE"
  echo "[dsh-web] dsh web started (pid $CHILD_PID)" >&2
  tail -f --pid="$CHILD_PID" "$LOG" &
}

# --- 会话自举 -----------------------------------------------------------------
# 已有 cookie 且仍被 dsh web 接受时直接复用(签名密钥持久化在数据卷凭据库,
# cookie 默认 30 天有效); 否则等待本次 dsh web 打印的 token 并换取。
ensure_session() {
  if [ -f "$COOKIE_FILE" ]; then
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Cookie: $(cat "$COOKIE_FILE")" "http://127.0.0.1:${WEB_PORT}/" || true)"
    if [ "$code" = "200" ]; then
      echo "[dsh-web] reusing the still-valid session cookie" >&2
      return 0
    fi
  fi
  local token="" headers="" cookie=""
  for _ in $(seq 1 120); do
    token="$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG" 2>/dev/null | tail -n1 | cut -d= -f2 || true)"
    [ -n "$token" ] && break
    if ! kill -0 "$CHILD_PID" 2>/dev/null; then
      echo "[dsh-web] dsh web exited before printing a login token; last log lines:" >&2
      tail -n 20 "$LOG" >&2 || true
      return 1
    fi
    sleep 1
  done
  if [ -z "$token" ]; then
    echo "[dsh-web] no login token printed by dsh web within 120s" >&2
    return 1
  fi
  headers="$(mktemp)"
  # token 打印与端口就绪之间可能存在小窗口, 换取请求做短重试。
  local exchanged=0
  for _ in $(seq 1 10); do
    if curl -sS -o /dev/null -D "$headers" "http://127.0.0.1:${WEB_PORT}/?token=${token}"; then
      exchanged=1
      break
    fi
    sleep 0.5
  done
  if [ "$exchanged" != "1" ]; then
    echo "[dsh-web] token exchange request failed" >&2
    rm -f "$headers"
    return 1
  fi
  # 头解析用 POSIX 安全写法(镜像里的 awk 是 mawk, 不支持 gawk 的 /i 标志),
  # 并去掉 curl -D 输出行尾的 \r。
  cookie="$(awk '/^[Ss]et-[Cc]ookie:/{sub(/^[Ss]et-[Cc]ookie:[ ]*/,""); sub(/;.*/,""); sub(/\r$/,""); print; exit}' "$headers")"
  rm -f "$headers"
  if [ -z "$cookie" ]; then
    echo "[dsh-web] token exchange produced no session cookie" >&2
    return 1
  fi
  # cookie 等价于会话凭证, 只留给本脚本的 Caddyfile 生成读取。
  umask 077
  printf '%s' "$cookie" > "$COOKIE_FILE"
  echo "[dsh-web] session cookie minted from the login token" >&2
}

# --- Caddyfile 生成 -----------------------------------------------------------
# header_up Cookie 用整头替换而不是追加: 注入的是内部 authority
# (127.0.0.1:$WEB_PORT)绑定的会话 cookie, 浏览器不可能持有同名 cookie,
# 替换可避免多 Cookie 头拼接在各端解析上的歧义。
generate_caddyfile() {
  local cookie
  cookie="$(cat "$COOKIE_FILE")"
  mkdir -p "$RUNTIME_DIR"
  # 缩进用 tab(caddy fmt 规范), 避免启动时 "Caddyfile input is not formatted" 警告。
  cat > "$CADDYFILE" <<EOF
{
	admin off
	auto_https off
}
:3081 {
	encode gzip
	# index.html 是动态启动清单(内联 bundle URL 与 rev): 必须禁缓存。否则镜像
	# 升级后浏览器会用旧前端调用已被移除的端点(旧 /api/events.mux ->
	# 新 /api/remote.mux), 表现为页面能开但事件流全部 502。
	@index path /
	header @index Cache-Control "no-store"
	reverse_proxy 127.0.0.1:${WEB_PORT} {
		header_up Host 127.0.0.1:${WEB_PORT}
		header_up Origin http://127.0.0.1:${WEB_PORT}
		header_up Cookie "${cookie}"
	}
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
	basicauth {
		$DSH_PROXY_USER $hash
	}
EOF
  fi
  printf '}\n' >> "$CADDYFILE"
  # 文件含 bcrypt 哈希(以及会话 cookie 的注入行), 仅运行时用户可读。
  chmod 600 "$CADDYFILE"
}

# --- Caddy 启动/重启 ------------------------------------------------------------
# 在最多约 5s 内等待代理端口可响应, 进程中途退出或始终无响应均 fail-fast
# (配置/端口错误不静默降级)。
start_caddy() {
  if [ -z "${DSH_PROXY_USER:-}" ] && [ -z "${DSH_PROXY_PASSWORD:-}" ]; then
    echo "[dsh-web] WARNING: the proxy listens on 0.0.0.0:3081 with NO authentication — set DSH_PROXY_USER + DSH_PROXY_PASSWORD before any non-loopback exposure (docs/security.md)" >&2
  fi
  caddy run --config "$CADDYFILE" --adapter caddyfile &
  CADDY_PID=$!
  local ready=0
  for _ in $(seq 1 20); do
    if ! caddy_alive "$CADDY_PID"; then
      echo "[dsh-web] caddy failed to start (config below):" >&2
      cat "$CADDYFILE" >&2
      return 1
    fi
    if curl -sS -o /dev/null "http://127.0.0.1:3081/" 2>/dev/null; then
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

# --- 栈引导: dsh web → 会话 cookie → Caddy -------------------------------------
mkdir -p "$RUNTIME_DIR"
start_dsh_web
if ! ensure_session; then
  echo "[dsh-web] session bootstrap failed; refusing to serve" >&2
  exit 1
fi
generate_caddyfile
if ! start_caddy; then
  exit 1
fi
echo "[dsh-web] caddy started (pid $CADDY_PID); stack ready on 0.0.0.0:3081 -> 127.0.0.1:${WEB_PORT}" >&2

last_cookie="$(cat "$COOKIE_FILE" 2>/dev/null || true)"

# --- 监督循环 -------------------------------------------------------------------
# 单线程轮询(2s): dsh web 退出则重启并重新自举会话(cookie 失效才重新换取,
# cookie 变化才重启 Caddy); caddy 崩溃则直接重启。若 dsh web/会话/Caddy
# 无法恢复, 以非零退出交给编排层重启容器 —— 不静默降级。
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
    if ! ensure_session; then
      echo "[dsh-web] session bootstrap failed after dsh web restart; giving up" >&2
      exit 1
    fi
    new_cookie="$(cat "$COOKIE_FILE" 2>/dev/null || true)"
    if [ "$new_cookie" != "$last_cookie" ]; then
      echo "[dsh-web] session cookie changed; regenerating caddy config" >&2
      generate_caddyfile || exit 1
      restart_caddy || exit 1
      last_cookie="$new_cookie"
    fi
  fi
  if [ -n "$CADDY_PID" ] && ! caddy_alive "$CADDY_PID"; then
    echo "[dsh-web] caddy exited; restarting" >&2
    restart_caddy || exit 1
  fi
  sleep 2
done

exit 0
