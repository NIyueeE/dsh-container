#!/usr/bin/env bash
# 将全局 @deepseek-ai/dsh 更新到 npm 最新版(幂等: 已是最新则不做任何事)。
# 离线或 npm 不可达时安全退出, 不影响容器启动。
set -euo pipefail

# 镜像以数值 USER 1000 运行, Docker 不会自动设置 HOME; 从 passwd 还原
# (npm 缓存、rustup 等工具依赖 HOME)。
export HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"

PACKAGE="@deepseek-ai/dsh"

installed="$(dsh --version 2>/dev/null || true)"
latest="$(npm view "$PACKAGE" version --no-fund --no-audit 2>/dev/null || true)"

if [ -z "$latest" ]; then
  echo "[dsh-update] npm registry unreachable; keeping installed dsh ($installed)" >&2
  exit 0
fi

if [ -z "$installed" ]; then
  echo "[dsh-update] installing $PACKAGE@$latest"
  npm install --global --no-fund --no-audit "$PACKAGE@$latest"
  echo "[dsh-update] installed $(dsh --version)"
  exit 0
fi

if [ "$installed" = "$latest" ]; then
  echo "[dsh-update] already up to date ($installed)"
else
  echo "[dsh-update] updating $installed -> $latest"
  npm install --global --no-fund --no-audit "$PACKAGE@$latest"
  echo "[dsh-update] now $(dsh --version)"
fi
