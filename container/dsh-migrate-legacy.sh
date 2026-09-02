#!/usr/bin/env bash
# 一次性迁移: 清除旧镜像遗留在持久化用户层的 npm 全局版 dsh。
#
# 旧镜像 (v0.2.x) 把 dsh 作为 npm 全局包装在 /home/dsh/.local
# (NPM_CONFIG_PREFIX), 该目录随数据卷持久化。新镜像的 dsh 改为镜像内
# 系统层 /opt/deepseek-harness (/usr/local/bin/dsh), 但旧卷中的副本仍在
# PATH 中遮蔽新版本。本脚本在容器启动时幂等地移除旧副本:
#   - ~/.local/lib/node_modules/@deepseek-ai/dsh (旧 npm 包及依赖)
#   - ~/.local/bin/dsh (npm 创建的入口, 可能是悬空符号链接)
# 用户层中的其他 npm 全局包 (无关包) 不受影响。
# 幂等: 无旧残留时立即退出。失败不阻塞容器启动 (rm 失败仅告警)。
set -euo pipefail

# 优先使用调用方 (entrypoint) 已设置的 HOME; 未设置时兜底从 passwd
# 还原 (容器以数值 USER 运行时不会自动设置 HOME)。
if [ -z "${HOME:-}" ]; then
  if ! HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"; then
    echo "[dsh-migrate-legacy] cannot resolve HOME for uid $(id -u)" >&2
    exit 1
  fi
fi
if [ -z "$HOME" ]; then
  echo "[dsh-migrate-legacy] empty HOME for uid $(id -u)" >&2
  exit 1
fi
export HOME

legacy_lib="$HOME/.local/lib/node_modules/@deepseek-ai/dsh"
legacy_bin="$HOME/.local/bin/dsh"

if [ ! -e "$legacy_lib" ] && [ ! -L "$legacy_lib" ] \
   && [ ! -e "$legacy_bin" ] && [ ! -L "$legacy_bin" ]; then
  exit 0
fi

echo "[dsh-migrate-legacy] removing legacy npm-installed dsh from the user layer; dsh now ships in the image (/usr/local/bin/dsh -> /opt/deepseek-harness)" >&2
rm -rf -- "$legacy_lib" 2>/dev/null || echo "[dsh-migrate-legacy] failed to remove $legacy_lib (continuing)" >&2
rm -f -- "$legacy_bin" 2>/dev/null || echo "[dsh-migrate-legacy] failed to remove $legacy_bin (continuing)" >&2
echo "[dsh-migrate-legacy] legacy dsh removed" >&2
