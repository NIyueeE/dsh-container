#!/usr/bin/env bash
# DeepSeek Harness 容器入口:
#   1. (可选) 把 dsh 自动更新到 npm 最新版, 默认开启(DSH_AUTO_UPDATE=1; 只升不降)
#   2. 解析默认路径: DSH_HOME 默认 $HOME/dsh, DSH_WORKSPACE 默认 $HOME/workspace
#      (universal 6.x 即 /home/codespace/dsh 与 /home/codespace/workspace;
#       旧版 2.x 等其它基础镜像自动跟随运行时用户的 home)
#   3. 以 `dsh web` 启动 Web UI, 监听 127.0.0.1:3080(npm 发布版与上游 main
#      均拒绝 --host 0.0.0.0)
#   4. Caddy 反向代理监听 0.0.0.0:3081: 把 Host/Origin 改写为回环后转发到
#      127.0.0.1:$PORT(默认 3080), 并对 UI 资源做 gzip 压缩(UI 静态资源约
#      1.3MB, 压缩后约 360KB, 远端访问显著更快); SSE/WebSocket 流式响应
#      不缓冲(Caddy 对 text/event-stream 即时 flush, WebSocket 直通)。
#      dsh 的 /api 信任围栏只检查 HTTP 头, 改写后远程浏览器也能通过全部
#      接口(含设置/凭据等原本仅回环的方法); 安全边界随之转移到代理 ——
#      设置 DSH_PROXY_USER + DSH_PROXY_PASSWORD 启用 basic auth
#      (见 docs/security.md)。
#   5. Caddy 运行期崩溃由守护循环自动重启; 配置错误在启动时 fail-fast,
#      持续不可用由 HEALTHCHECK 标 unhealthy, 交给编排层重启容器。
# 附加参数会原样透传给 dsh web, 例如 --port 8080。
set -euo pipefail

# 数值 USER 不自动设置 HOME; 从 passwd 还原, 供 npm/uv/cargo 等使用。
export HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"

# 默认路径放在容器用户 home 下(universal 6.x = /home/codespace), 旧版 2.x
# (vscode 用户)自动跟随其 home; 显式设置的环境变量优先。目录缺失时创建,
# 并切到工作区作为 dsh 的工作目录。
export DSH_HOME="${DSH_HOME:-$HOME/dsh}"
export DSH_WORKSPACE="${DSH_WORKSPACE:-$HOME/workspace}"
mkdir -p "$DSH_HOME" "$DSH_WORKSPACE"
cd "$DSH_WORKSPACE"

# 只更新不启动: 供 systemd timer / cron 定时更新 dsh 使用。
if [ "${DSH_UPDATE_ONLY:-0}" = "1" ]; then
  exec dsh-update
fi

# 自动更新失败(如离线)时沿用镜像内已装版本继续启动。
if [ "${DSH_AUTO_UPDATE:-1}" = "1" ]; then
  if ! dsh-update; then
    echo "[entrypoint] dsh auto-update failed; continuing with installed version" >&2
  fi
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
if [ -n "${DSH_PROXY_USER:-}" ] && [ -n "${DSH_PROXY_PASSWORD:-}" ]; then
  PROXY_HASH="$(caddy hash-password --plaintext "$DSH_PROXY_PASSWORD" 2>/dev/null)"
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

# 启动 Caddy: 配置/端口错误在 0.5s 内 fail-fast, 直接退出容器。
caddy run --config "$CADDYFILE" --adapter caddyfile &
CADDY_PID=$!
sleep 0.5
if ! caddy_alive "$CADDY_PID"; then
  echo "[entrypoint] caddy failed to start (config below):" >&2
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

exec dsh web "$@"
