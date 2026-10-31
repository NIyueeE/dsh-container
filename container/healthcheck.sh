#!/usr/bin/env bash
# 容器健康检查: dsh web(内部端口)与 Caddy 反代(3081)都必须返回预期的
# 未登录状态, 而不只是 TCP 可连接 —— 500/502 也代表栈不可用。
# dsh web 对无会话的根请求返回 401; Caddy 的登录重定向返回 302, 配置 basic
# auth 时无凭据返回 401。--noproxy 保证容器里配置了 HTTP(S)_PROXY 时健康检查
# 仍直连回环。
# 内部端口取 entrypoint 解析 --port 后写入 pid1 环境的 DSH_WEB_PORT(容器以
# USER dsh 运行, 与 pid1 同 uid, 可读 /proc/1/environ); 兜底 3080。
set -u

port="${DSH_WEB_PORT:-3080}"
env_port="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^DSH_WEB_PORT=//p' | head -n1)"
[ -n "$env_port" ] && port="$env_port"

# 只看 TCP 可连接会把 500/502 甚至错误服务误判为健康; 校验预期的鉴权状态码:
# 直连 dsh 根路径无 cookie 是 401; Caddy 无 cookie 是 302(登录重定向), 配置了
# basic auth 时则是 401。
direct_code="$(curl -sS --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:${port}/" 2>/dev/null || true)"
if [ "$direct_code" != "401" ]; then
  echo "healthcheck: dsh on 127.0.0.1:${port} returned '${direct_code:-none}', expected 401" >&2
  exit 1
fi

proxy_code="$(curl -sS --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:3081/" 2>/dev/null || true)"
case "$proxy_code" in
  302|401) ;;
  *)
    echo "healthcheck: Caddy on 127.0.0.1:3081 returned '${proxy_code:-none}', expected 302 (no auth) or 401 (basic auth)" >&2
    exit 1
    ;;
esac
