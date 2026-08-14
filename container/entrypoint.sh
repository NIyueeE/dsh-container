#!/usr/bin/env bash
# DeepSeek Harness 容器入口:
#   1. (可选) 把 dsh 自动更新到 npm 最新版, 默认开启(DSH_AUTO_UPDATE=1)
#   2. 解析默认路径: DSH_HOME 默认 $HOME/dsh, DSH_WORKSPACE 默认 $HOME/workspace
#      (universal 6.x 即 /home/codespace/dsh 与 /home/codespace/workspace;
#       旧版 2.x 等其它基础镜像自动跟随运行时用户的 home)
#   3. 以 `dsh web` 启动 Web UI, 监听 127.0.0.1:3080(npm 发布版拒绝 --host 0.0.0.0)
#   4. 由 socat 监听 0.0.0.0:3081 转发到 127.0.0.1:$PORT(默认 3080)对外暴露:
#      转发端口与 dsh 监听端口错开, 可直接绑定通配地址(无需容器 IP 探测);
#      端口映射与示例统一用 3081, 只在本机使用时不发布端口即可。
#   5. DSH_TRUSTED_HOSTS(空格或逗号分隔的 host[:port] 列表)逐个转成
#      `--trusted-host`, 供 /api 浏览器信任围栏放行非回环访问。
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

# 从附加参数中提取 --port <N> / --port=<N>, 使 socat 转发目标与 dsh 实际
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

# 对外暴露: socat 监听 0.0.0.0:3081, 转发到 dsh 的 127.0.0.1:$PORT。
# 端口与 dsh 错开(3081 != $PORT), 因此可以直接绑定通配地址, 无需像以前那样
# 探测容器 IP 规避 EADDRINUSE。端口被占用时立即失败, 不静默降级。
socat TCP-LISTEN:3081,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:"$PORT" &
sleep 0.3
kill -0 $! 2>/dev/null || { echo "[entrypoint] socat failed to bind 0.0.0.0:3081" >&2; exit 1; }

# DSH_TRUSTED_HOSTS: 空格或逗号分隔的 host[:port] 列表(与附加参数中的
# --trusted-host 并存, 取并集)。裸 host 表示该主机名任意端口均信任。
args=("$@")
if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
  IFS=' ,' read -ra trusted <<< "$DSH_TRUSTED_HOSTS" || true
  for t in "${trusted[@]}"; do
    [ -n "$t" ] && args+=(--trusted-host "$t")
  done
fi

exec dsh web "${args[@]}"
