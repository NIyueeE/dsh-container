#!/usr/bin/env bash
# DeepSeek Harness 容器入口:
#   1. (可选) 把 dsh 自动更新到 npm 最新版, 默认开启(DSH_AUTO_UPDATE=1)
#   2. 以 `dsh web` 启动 Web UI, 默认监听 0.0.0.0:3080(DSH_WEB_HOST,
#      上游 dsh 默认仅 127.0.0.1; 设 DSH_WEB_HOST=127.0.0.1 恢复仅回环)
# 附加参数会原样透传给 dsh web, 例如 --port 8080。
set -euo pipefail

# 数值 USER 不自动设置 HOME; 从 passwd 还原, 供 npm/uv/cargo 等使用。
export HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"

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

exec dsh web --host "${DSH_WEB_HOST:-0.0.0.0}" "$@"
