#!/usr/bin/env bash
# dsh web 守护脚本:
#   以前台方式运行 `dsh web`, 崩溃/退出后自动重新拉起;
#   配合 `dsh-restart` 可在容器内部重启 dsh web(向当前子进程发 SIGTERM)。
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

# 确保用户级工具在 PATH 中, 并把工作目录切到 $HOME(dsh 的工作区)。
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME"

# 容器内没有浏览器: 默认补上 --no-open, 避免每次启动 dsh web 都尝试打开
# 默认浏览器(无浏览器环境下上游只会打印打开失败的错误)。用户已显式传入
# --no-open 时不重复添加。
case " $* " in
  *" --no-open "*) : ;;
  *) set -- "$@" --no-open ;;
esac

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
  # 每次启动前重打前端兼容补丁(幂等, 已打过则跳过): 构建产物在系统层
  # /opt/deepseek-harness, 镜像构建时已打, 运行时再打一次兜底。
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
