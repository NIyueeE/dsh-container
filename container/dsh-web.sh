#!/usr/bin/env bash
# dsh web 守护脚本:
#   以前台方式运行 `dsh web`, 崩溃/退出后自动重新拉起;
#   配合 `dsh-restart` 可在容器内部重启 dsh web(向当前子进程发 SIGTERM)。
# 附加参数会原样透传给 dsh web, 例如 --port 8080。
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

# 确保用户级工具(dsh 等)在 PATH 中，并把工作目录切到 $HOME(dsh 的工作区)。
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME"

PIDFILE=/tmp/dsh-web.pid
CHILD_PID=""
STOPPING=0

cleanup() {
  STOPPING=1
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}
trap cleanup TERM INT EXIT

while [ "$STOPPING" = "0" ]; do
  # 每次启动前重打前端兼容补丁: dsh 自动更新或手动 dsh-update 会覆盖已打补丁
  # 的文件, 而 dsh-restart 只重启 dsh web 子进程, 不会重跑 entrypoint。
  if command -v dsh-client-patch >/dev/null 2>&1; then
    dsh-client-patch || echo "[dsh-web] dsh-client-patch failed; continuing" >&2
  fi
  dsh web "$@" &
  CHILD_PID=$!
  echo "$CHILD_PID" > "$PIDFILE"
  echo "[dsh-web] dsh web started (pid $CHILD_PID)" >&2

  set +e
  wait "$CHILD_PID"
  status=$?
  set -e

  rm -f "$PIDFILE"
  CHILD_PID=""

  if [ "$STOPPING" = "1" ]; then
    echo "[dsh-web] stopping" >&2
    break
  fi

  echo "[dsh-web] dsh web exited (status $status); restarting in 2s" >&2
  sleep 2
done

exit 0
