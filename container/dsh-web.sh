#!/usr/bin/env bash
# dsh web 守护脚本(容器内整个服务栈的监督者):
#   1. 启动 `dsh web`(输出写入日志文件并 tail 镜像到 stdout, 容器日志仍可见),
#      退出/崩溃后自动重新拉起; 配合 `dsh-restart` 可在容器内部重启 dsh web。
#      启动命令挂载镜像自带的容器适配插件 overlay(--patch, launcher flag,
#      必须位于 `web` 之前): 会话 cookie 自举由插件在 dsh 进程内完成, 不再
#      由本脚本 grep 日志 token + curl 交换。
#   2. 等待插件写出的会话 cookie(/tmp/dsh-caddy/session-cookie), 随后生成的
#      Caddyfile 把该 cookie 注入所有代理请求。dsh 的签名密钥持久化在数据卷
#      凭据库中, cookie 默认 30 天有效、跨进程/跨容器重启有效 —— 插件会复用
#      仍被接受的旧 cookie, 不重复换取。dsh 自身的浏览器围栏
#      (3080 直连无 cookie 仍 401)原样保留, 3081 上的鉴权由 Caddy 承担
#      (basic auth / 网络暴露面)。
#   3. 启动 Caddy 反代监听 0.0.0.0:3081: 把 Host/Origin 改写为回环后转发到
#      127.0.0.1:$DSH_WEB_PORT, 并注入会话 cookie(UI 资源压缩由上游 dsh 的
#      webserver 自带 gzip 承担, Caddy 不再重复压缩); 运行期崩溃自动重启
#      (配置错误 fail-fast)。DSH_PROXY_USER + DSH_PROXY_PASSWORD 必须成对设置
#      以启用 basic auth, 只设置一个直接退出。
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
case " $* " in
  *" --no-open "*) WEB_ARGS=("$@") ;;
  *) WEB_ARGS=("$@" "--no-open") ;;
esac

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
# 全部输出(含一次性登录 token 与报错)。启动命令在 `web` 之前挂载容器适配
# 插件 overlay(--patch 是 launcher flag), 会话 cookie 自举由插件完成。
start_dsh_web() {
  : > "$LOG"
  # 每次启动前重打浏览器端兼容补丁(幂等, 已打过则跳过): 构建产物在系统层
  # /opt/deepseek-harness, 镜像构建时已打, 运行时再打一次兜底。
  if [ -f /opt/dsh-container-plugin/scripts/patch-client.js ]; then
    node /opt/dsh-container-plugin/scripts/patch-client.js \
      || echo "[dsh-web] patch-client failed; continuing" >&2
  fi
  dsh --patch /opt/dsh-container-plugin/overlay.yml web "${WEB_ARGS[@]}" >>"$LOG" 2>&1 &
  CHILD_PID=$!
  echo "$CHILD_PID" > "$PIDFILE"
  echo "[dsh-web] dsh web started (pid $CHILD_PID)" >&2
  tail -f --pid="$CHILD_PID" "$LOG" &
}

# --- 会话自举 -----------------------------------------------------------------
# 由插件在 dsh 进程内完成(token → cookie, 复用仍有效的旧 cookie), 本脚本
# 只等待插件写出的 cookie 文件出现; 超时则 fail-fast, 与旧实现等价。
ensure_session() {
  for _ in $(seq 1 120); do
    if [ -s "$COOKIE_FILE" ]; then
      echo "[dsh-web] session cookie ready (minted by the container-adapt plugin)" >&2
      return 0
    fi
    if ! kill -0 "$CHILD_PID" 2>/dev/null; then
      echo "[dsh-web] dsh web exited before the session cookie appeared; last log lines:" >&2
      tail -n 20 "$LOG" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "[dsh-web] no session cookie from the container-adapt plugin within 120s" >&2
  return 1
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
