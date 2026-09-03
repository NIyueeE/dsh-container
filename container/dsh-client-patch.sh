#!/usr/bin/env bash
# dsh-container: 为远程使用打幂等的前端兼容补丁。
#
# Caddy 反代已经把 Host/Origin 改写成回环, 因此 dsh 的服务端 /api 信任围栏
# 会放行所有特权接口。但上游 dsh 的浏览器代码仍按 window.location.hostname
# 判断是否回环, 导致远程浏览器无法使用设置/凭据等页面。本脚本把浏览器端
# 视为回环, 并补上 crypto.randomUUID polyfill, 让纯 HTTP 内网也能工作。
#
# 设计为 best-effort: 若上游 dsh 版本改变了 bundle 路径或源码字符串, 脚本
# 打印警告并跳过, 而不是阻止 dsh web 启动。CI 应能捕获这类版本漂移。
#
# 上游核对(dsh-v0.1.2-rc.1): 相对 alpha.5 仅 package.json 版本号变更, 无源码
# 改动 —— isLoopback 表达式原样保留(connection/src/client/index.ts:228),
# isLoopbackHostname 未变; 本补丁仍然必需(新增的 trustedHosts 只作用于服务端
# 请求围栏, 不影响浏览器侧设置/凭据页的门)。上游已自带不依赖 secure context
# 的 randomUuid(), randomUUID polyfill 仅作为其余 bundle 代码的保险。
set -euo pipefail

# 允许显式覆盖(测试用); 默认使用镜像内源码构建的 dsh 产物。
if [ -z "${HOME:-}" ]; then
  HOME="$(getent passwd "$(id -u)" | cut -d: -f6)" || true
  export HOME
fi
if [ -z "${HOME:-}" ]; then
  echo "[dsh-client-patch] cannot resolve HOME; skipping" >&2
  exit 0
fi

DSH_PKG_ROOT="${DSH_CLIENT_PATCH_ROOT:-/opt/deepseek-harness}"
if [ ! -d "$DSH_PKG_ROOT" ]; then
  echo "[dsh-client-patch] dsh source tree not found at $DSH_PKG_ROOT; skipping" >&2
  exit 0
fi

# 源码构建布局(默认)与 npm 全局安装布局(旧版兼容)都支持。
CONNECTION_BUNDLE=""
for candidate in \
  "$DSH_PKG_ROOT/packages/client/connection/lib/client.js" \
  "$DSH_PKG_ROOT/node_modules/@deepseek-ai/dsh-client-connection/lib/client.js"; do
  if [ -f "$candidate" ]; then
    CONNECTION_BUNDLE="$candidate"
    break
  fi
done
if [ -z "$CONNECTION_BUNDLE" ]; then
  CONNECTION_BUNDLE="$(find "$DSH_PKG_ROOT" -path '*/@deepseek-ai/dsh-client-connection/lib/client.js' -print -quit)"
fi

INDEX_HTML=""
for candidate in \
  "$DSH_PKG_ROOT/apps/web/dist/index.html" \
  "$DSH_PKG_ROOT/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html"; do
  if [ -f "$candidate" ]; then
    INDEX_HTML="$candidate"
    break
  fi
done
if [ -z "$INDEX_HTML" ]; then
  INDEX_HTML="$(find "$DSH_PKG_ROOT" -path '*/@deepseek-ai/dsh-web-frontend/dist/index.html' -print -quit)"
fi

patch_connection() {
  if [ -z "$CONNECTION_BUNDLE" ]; then
    echo "[dsh-client-patch] dsh-client-connection bundle not found; skipping isLoopback patch" >&2
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'NODE'
const fs = require('fs')
const file = process.env.CONNECTION_BUNDLE
const marker = 'dsh-container remote-proxy patch'
const candidates = [
  'isLoopback: transport?.ownsHost === true || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),',
  'isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),',
]
const neu = 'isLoopback: true, // ' + marker
let src = fs.readFileSync(file, 'utf8')
if (src.includes(marker)) {
  console.log('[dsh-client-patch] isLoopback already patched')
  process.exit(0)
}
const old = candidates.find((candidate) => src.includes(candidate))
if (old === undefined) {
  console.error('[dsh-client-patch] isLoopback pattern not found; upstream may have changed; skipping')
  process.exit(2)
}
src = src.split(old).join(neu)
fs.writeFileSync(file, src)
console.log('[dsh-client-patch] isLoopback patched')
NODE

  set +e
  CONNECTION_BUNDLE="$CONNECTION_BUNDLE" node "$tmp"
  status=$?
  set -e
  rm -f "$tmp"

  if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
    echo "[dsh-client-patch] unexpected error patching connection bundle" >&2
  fi
}

patch_index() {
  if [ -z "$INDEX_HTML" ]; then
    echo "[dsh-client-patch] dsh-web-frontend index.html not found; skipping randomUUID polyfill" >&2
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'NODE'
const fs = require('fs')
const file = process.env.INDEX_HTML
const marker = 'dsh-container randomUUID polyfill'
const anchor = '<script type="module"'
const polyfill = `<!-- dsh-container randomUUID polyfill -->
<script>
(function () {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID !== 'function') {
    crypto.randomUUID = function () {
      var b = crypto.getRandomValues(new Uint8Array(16));
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      var h = '';
      for (var i = 0; i < b.length; i++) h += (b[i] < 16 ? '0' : '') + b[i].toString(16);
      return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
    };
  }
})();
</script>
`
let html = fs.readFileSync(file, 'utf8')
if (html.includes(marker)) {
  console.log('[dsh-client-patch] randomUUID polyfill already present')
  process.exit(0)
}
const at = html.indexOf(anchor)
if (at === -1) {
  console.error('[dsh-client-patch] module script anchor not found; upstream may have changed; skipping')
  process.exit(2)
}
html = html.slice(0, at) + polyfill + html.slice(at)
fs.writeFileSync(file, html)
console.log('[dsh-client-patch] randomUUID polyfill injected')
NODE

  set +e
  INDEX_HTML="$INDEX_HTML" node "$tmp"
  status=$?
  set -e
  rm -f "$tmp"

  if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
    echo "[dsh-client-patch] unexpected error patching index.html" >&2
  fi
}

patch_connection
patch_index

echo '[dsh-client-patch] done'
