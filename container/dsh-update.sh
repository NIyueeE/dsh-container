#!/usr/bin/env bash
# 将全局 @deepseek-ai/dsh 更新到 npm 最新版(幂等: 已是最新则不做任何事;
# 只升不降 —— 构建期固定的版本比 npm latest 新时保持不变)。
# 离线或 npm 不可达时安全退出, 不影响容器启动。
set -euo pipefail

# 镜像以数值 USER 1000 运行, Docker 不会自动设置 HOME; 从 passwd 还原
# (npm 缓存、rustup 等工具依赖 HOME)。用 if ! 捕获 getent 失败并校验非空。
if ! HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"; then
  echo "[dsh-update] cannot resolve HOME for uid $(id -u)" >&2
  exit 1
fi
if [ -z "$HOME" ]; then
  echo "[dsh-update] empty HOME for uid $(id -u)" >&2
  exit 1
fi
export HOME

PACKAGE="@deepseek-ai/dsh"

installed="$(dsh --version 2>/dev/null | head -n 1 | tr -d '\r\n' | sed 's/^v//' || true)"
latest="$(npm view "$PACKAGE" version --no-fund --no-audit 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"

if [ -z "$latest" ]; then
  echo "[dsh-update] npm registry unreachable; keeping installed dsh ($installed)" >&2
  exit 0
fi

if [ -z "$installed" ]; then
  echo "[dsh-update] installing $PACKAGE@$latest"
  npm install --global --no-fund --no-audit --dangerously-allow-all-scripts "$PACKAGE@$latest"
  if ! installed="$(dsh --version 2>/dev/null | head -n 1 | tr -d '\r\n' || true)" || [ -z "$installed" ]; then
    echo "[dsh-update] install finished but dsh --version still fails" >&2
    exit 1
  fi
  echo "[dsh-update] installed $installed"
  exit 0
fi

if [ "$installed" = "$latest" ]; then
  echo "[dsh-update] already up to date ($installed)"
  exit 0
fi

# 只升不降: 仅当 installed < npm latest 时才更新。node 比较器返回 0 表示
# installed >= latest(无需更新), 返回 1 表示需要更新; 外层 if 直接判断。
if node -e '
  const a = process.argv[1], b = process.argv[2];
  const f = (v) => {
    const [core, pre] = (v || "").replace(/^v/, "").split("+")[0].split("-");
    const parts = core.split(".").map((n) => parseInt(n, 10) || 0);
    while (parts.length < 3) parts.push(0);
    return { core: parts.slice(0, 3), pre: pre ? pre.split(".") : null };
  };
  const cmp = (x, y) => {
    for (let i = 0; i < 3; i++) {
      if (x.core[i] !== y.core[i]) return x.core[i] > y.core[i] ? 1 : -1;
    }
    if (x.pre === null && y.pre === null) return 0;
    if (x.pre === null) return 1;
    if (y.pre === null) return -1;
    const n = Math.max(x.pre.length, y.pre.length);
    for (let i = 0; i < n; i++) {
      const p = x.pre[i] ?? "0", q = y.pre[i] ?? "0";
      const np = /^\d+$/.test(p) ? parseInt(p, 10) : null;
      const nq = /^\d+$/.test(q) ? parseInt(q, 10) : null;
      if (np !== null && nq !== null) {
        if (np !== nq) return np > nq ? 1 : -1;
      } else if (p !== q) {
        return p > q ? 1 : -1;
      }
    }
    return 0;
  };
  process.exit(cmp(f(a), f(b)) >= 0 ? 0 : 1);
' "$installed" "$latest"; then
  echo "[dsh-update] npm latest $latest is not newer than installed $installed; keeping it"
  exit 0
fi

# --dangerously-allow-all-scripts: npm 11.16+ 的 allow-scripts 机制默认
# 放行未审批脚本, 但未来 npm 可能默认收紧(approve-scripts 明确不支持
# 全局安装), 显式声明允许 install scripts(原生模块 node-pty/koffi 等
# 依赖), 避免静默产出原生模块缺失的坏安装。
echo "[dsh-update] updating $installed -> $latest"
npm install --global --no-fund --no-audit --dangerously-allow-all-scripts "$PACKAGE@$latest"
if ! installed="$(dsh --version 2>/dev/null | head -n 1 | tr -d '\r\n' || true)" || [ -z "$installed" ]; then
  echo "[dsh-update] update finished but dsh --version still fails" >&2
  exit 1
fi
echo "[dsh-update] now $installed"
