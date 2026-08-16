#!/usr/bin/env bash
# 在容器内部重启 dsh web:
#   读取 dsh-web 守护脚本维护的 PID 文件, 向当前 dsh web 子进程发送 SIGTERM,
#   由 dsh-web 自动重新拉起。
set -euo pipefail

PIDFILE=/tmp/dsh-web.pid

if [ ! -f "$PIDFILE" ]; then
  echo "[dsh-restart] no pid file at $PIDFILE (dsh-web not running?)" >&2
  exit 1
fi

pid="$(cat "$PIDFILE" 2>/dev/null || true)"
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "[dsh-restart] dsh web pid '$pid' is not running; removing stale pid file" >&2
  rm -f "$PIDFILE"
  exit 1
fi

echo "[dsh-restart] restarting dsh web (pid $pid)" >&2
kill "$pid"
