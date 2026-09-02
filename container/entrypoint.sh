#!/usr/bin/env bash
# DeepSeek Harness 容器入口:
#   1. 还原 HOME(数值 USER 1000 不会自动设置)
#   2. 使用默认用户层路径: dsh 数据 ~/.dsh(上游默认, 不设 DSH_HOME),
#      进程 cwd 直接使用 $HOME(dsh 按需在 $HOME 下创建目录);
#      Rust/cargo、uv、pnpm 都在 ~/ 下的用户级目录, 整个 home 由数据卷持久化;
#      dsh 本体在系统层 /opt/deepseek-harness, 随镜像更新, 不在用户数据卷中;
#      PATH 镜像优先 (/usr/local/bin 最前), 旧卷遗留的 npm 版 dsh 会在启动时
#      被 dsh-migrate-legacy 幂等清除, 不会遮蔽镜像内新版本
#   3. 解析 --port <N> / --port=<N>(默认 3080; 拒绝 0 与 3081)
#   4. 启动 Caddy 反向代理监听 0.0.0.0:3081: 把 Host/Origin 改写为回环后转发到
#      127.0.0.1:$PORT, 并对 UI 资源做 gzip 压缩(UI 静态资源约
#      1.3MB, 压缩后约 360KB, 远端访问显著更快); SSE/WebSocket 流式响应
#      不缓冲(Caddy 对 text/event-stream 即时 flush, WebSocket 直通)。
#      dsh 的 /api 信任围栏只检查 HTTP 头, 改写后远程浏览器也能通过全部
#      接口(含设置/凭据等原本仅回环的方法); 安全边界随之转移到代理 ——
#      DSH_PROXY_USER + DSH_PROXY_PASSWORD 必须成对设置以启用 basic auth,
#      只设置一个会直接退出(fail closed), 详见 docs/security.md。
#   5. 通过 `dsh-web` 守护脚本启动 Web UI, 监听 127.0.0.1:3080
#      (上游 tag 与 main 均拒绝 --host 0.0.0.0); dsh web 崩溃/退出后
#      会自动重新拉起, 容器内部可用 `dsh-restart` 手动重启 dsh web。
#      dsh web 会打印带 ?token=... 的一次性登录 URL 到容器日志, 通过对外
#      3081 端口打开该 URL 即可换取浏览器会话 cookie。
#      dsh-web 每次启动前会运行 dsh-client-patch, 把经代理的远程浏览器视为
#      回环并注入 crypto.randomUUID polyfill(见 container/dsh-client-patch.sh)。
#   6. Caddy 运行期崩溃由守护循环自动重启; 配置错误在启动时 fail-fast,
#      持续不可用由 HEALTHCHECK 标 unhealthy, 交给编排层重启容器。
# 附加参数会原样透传给 dsh web, 例如 --port 8080。
set -euo pipefail

# 数值 USER 不自动设置 HOME; 从 passwd 还原, 供 npm/uv/cargo 等使用。
# 用 if ! 捕获 getent 失败, 再校验非空, 不退化到 /dsh 这类根路径。
if ! HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"; then
  echo "[entrypoint] cannot resolve HOME for uid $(id -u)" >&2
  exit 1
fi
if [ -z "$HOME" ]; then
  echo "[entrypoint] empty HOME for uid $(id -u)" >&2
  exit 1
fi
export HOME

# 用户层状态都在 /home/dsh 下并整体持久化:
# - dsh 数据不设置 DSH_HOME, 使用上游默认 ~/.dsh
# - dsh 的 cwd 固定为 $HOME; 不预创建固定工作区目录, dsh 会按需创建
# - Rust/cargo: ~/.rustup + ~/.cargo
# - uv: ~/.local/bin, Python/tool 数据用 uv 默认的 ~/.local/share/uv、~/.cache/uv
# - pnpm: ~/.local/share/pnpm
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
mkdir -p "$HOME/.cargo/bin" "$HOME/.local/bin" "$PNPM_HOME"
# PATH 镜像优先 (hermes-agent 模式): 镜像提供的 dsh (/usr/local/bin ->
# /opt/deepseek-harness) 必须压过用户层; 用户层工具 (uv/pnpm/cargo 与
# /usr/local/bin 中的符号链接同源) 不受影响。
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME"

# 迁移: 旧镜像 (v0.2.x) 曾把 dsh 作为 npm 全局包装进持久化用户层
# (~/.local), 旧数据卷会遮蔽镜像内新版本; 启动时幂等清除旧副本
# (失败仅告警, 不阻塞启动), 详见 container/dsh-migrate-legacy.sh。
if ! dsh-migrate-legacy; then
  echo "[entrypoint] legacy dsh migration failed; continuing" >&2
fi

# 从附加参数中提取 --port <N> / --port=<N>, 使 Caddy 转发目标与 dsh 实际
# 监听端口一致(对外端口固定 3081, 不受影响)。
PORT=3080
prev=
for a in "$@"; do
  case "$a" in
    --port=*) PORT="${a#--port=}" ;;
  esac
  if [ "$prev" = "--port" ]; then PORT="$a"; fi
  prev="$a"
done
case "$PORT" in
  ''|*[!0-9]*)
    echo "[entrypoint] invalid --port value: '$PORT' (must be a number)" >&2
    exit 1
    ;;
esac
if [ "$PORT" = "0" ]; then
  echo "[entrypoint] --port 0 is not supported: the Caddy proxy needs a fixed internal port" >&2
  exit 1
fi
if [ "$PORT" = "3081" ]; then
  echo "[entrypoint] --port 3081 conflicts with the exposed Caddy proxy port; choose a different internal port" >&2
  exit 1
fi

# 对外暴露: Caddy 反向代理监听 0.0.0.0:3081, 把 Host/Origin 改写为回环后
# 转发到 dsh 的 127.0.0.1:$PORT。dsh 的 /api 信任围栏只看 HTTP 头, 因此经
# 代理的远程访问也能通过全部接口 —— 包括设置/凭据等原本仅回环放行的特权
# 方法。**安全边界随之转移到代理**: 能访问 3081 的任何人都可以读取/修改
# 全部配置与凭据, 必须配合 basic auth(下面两个变量)或防火墙/反代收口,
# 详见 docs/security.md。设置 DSH_PROXY_USER + DSH_PROXY_PASSWORD 启用认证。
# gzip 压缩对 SSE/WebSocket 无影响(Caddy 对 text/event-stream 即时 flush、
# WebSocket 直通, 实测不引入缓冲延迟)。Caddy 启动失败(如配置错误)时立即
# 退出, 不静默降级; 运行期崩溃由下方守护循环自动重启。
mkdir -p /tmp/dsh-caddy
CADDYFILE=/tmp/dsh-caddy/Caddyfile
# 缩进用 tab(caddy fmt 规范), 避免启动时 "Caddyfile input is not formatted" 警告。
cat > "$CADDYFILE" <<EOF
{
	admin off
	auto_https off
}
:3081 {
	encode gzip
	reverse_proxy 127.0.0.1:$PORT {
		header_up Host 127.0.0.1:$PORT
		header_up Origin http://127.0.0.1:$PORT
	}
EOF
if [ -n "${DSH_PROXY_USER:-}" ] || [ -n "${DSH_PROXY_PASSWORD:-}" ]; then
  # 只设置一个变量时 fail closed: 静默跳过 basic auth 会让用户以为已启用认证。
  if [ -z "${DSH_PROXY_USER:-}" ] || [ -z "${DSH_PROXY_PASSWORD:-}" ]; then
    echo "[entrypoint] DSH_PROXY_USER and DSH_PROXY_PASSWORD must be set together (refusing to start without auth)" >&2
    exit 1
  fi
  case "$DSH_PROXY_USER" in
    *[!A-Za-z0-9_.@-]*) echo "[entrypoint] invalid DSH_PROXY_USER: '$DSH_PROXY_USER'" >&2; exit 1 ;;
  esac
  # 通过 stdin 哈希, 避免密码出现在 caddy hash-password 的进程 argv 里。
  # caddy 从 stdin 逐行读取并去除末尾换行, 因此 printf 需要补一个 \n。
  if ! PROXY_HASH="$(printf '%s\n' "$DSH_PROXY_PASSWORD" | caddy hash-password 2>/dev/null)"; then
    echo "[entrypoint] failed to hash DSH_PROXY_PASSWORD" >&2
    exit 1
  fi
  # 发行版 caddy 2.6 的 Caddyfile 指令是 basicauth(2.7 起才叫 basic_auth);
  # bcrypt 哈希以 $ 开头即 Modular Crypt Format, 直接写原样, 无需 base64/转义。
  cat >> "$CADDYFILE" <<EOF
	basicauth {
		$DSH_PROXY_USER $PROXY_HASH
	}
EOF
fi
cat >> "$CADDYFILE" <<'EOF'
}
EOF

# caddy 存活检查: kill -0 对僵尸进程也返回成功(caddy 的父进程是 dsh web,
# 不会回收子进程), 必须通过 /proc 状态排除 Z。
caddy_alive() {
  local st
  st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  st="${st#*) }"
  case "$st" in
    Z*) return 1 ;;
  esac
  return 0
}

# 启动 Caddy: 在最多约 5s 内等待代理端口可响应, 进程中途退出或始终无响应
# 均 fail-fast(配置/端口错误不静默降级)。
caddy run --config "$CADDYFILE" --adapter caddyfile &
CADDY_PID=$!
CADDY_READY=0
for _ in $(seq 1 20); do
  if ! caddy_alive "$CADDY_PID"; then
    echo "[entrypoint] caddy failed to start (config below):" >&2
    cat "$CADDYFILE" >&2
    exit 1
  fi
  if curl -sS -o /dev/null http://127.0.0.1:3081/ 2>/dev/null; then
    CADDY_READY=1
    break
  fi
  sleep 0.25
done
if [ "$CADDY_READY" != "1" ]; then
  echo "[entrypoint] caddy did not become ready on 127.0.0.1:3081 (config below):" >&2
  cat "$CADDYFILE" >&2
  exit 1
fi

# 守护循环: 运行期崩溃自动重启(配置错误已在上方 fail-fast); 若 caddy
# 持续不可用, HEALTHCHECK(curl 3081)会标记 unhealthy, 由编排层重启容器
# —— 不静默降级。
(
  while :; do
    sleep 5
    if ! caddy_alive "$CADDY_PID"; then
      echo "[entrypoint] caddy exited; restarting" >&2
      caddy run --config "$CADDYFILE" --adapter caddyfile &
      CADDY_PID=$!
    fi
  done
) &

exec dsh-web "$@"
