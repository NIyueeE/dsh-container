#!/usr/bin/env bash
# 容器健康检查: dsh web(内部端口)与 Caddy 反代(3081)都可连接即视为健康。
# dsh web 对无会话的根请求返回 401, 因此用 curl 的退出码(连接成功)而不是
# HTTP 200 作为存活判据 —— 与旧的内联 HEALTHCHECK 语义一致。
# 内部端口取 entrypoint 解析 --port 后写入 pid1 环境的 DSH_WEB_PORT(容器以
# USER dsh 运行, 与 pid1 同 uid, 可读 /proc/1/environ); 兜底 3080。
set -u

port="${DSH_WEB_PORT:-3080}"
env_port="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^DSH_WEB_PORT=//p' | head -n1)"
[ -n "$env_port" ] && port="$env_port"

curl -sS -o /dev/null "http://127.0.0.1:${port}/" || exit 1
curl -sS -o /dev/null "http://127.0.0.1:3081/" || exit 1
