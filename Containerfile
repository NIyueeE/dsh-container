# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh) 容器镜像
#
# 基础镜像: mcr.microsoft.com/devcontainers/universal —— 微软通用开发容器
# (体积大但开箱即用, 自带 Node.js/nvm、Python、Go、Java、Docker CLI 等工具链)。
# 在此之上补装 Rust/cargo 与 uv, 并按官方仓库
# https://github.com/deepseek-ai/deepseek-harness 介绍的 npm 方式安装 dsh。
#
# 运行时行为由 container/entrypoint.sh 控制:
#   - 启动时自动把 dsh 更新到 npm 最新版(DSH_AUTO_UPDATE=1, 默认开启)
#   - 随后以 `dsh web` 启动 Web UI, 默认监听 127.0.0.1:3080
#     (dsh 出于安全考虑拒绝 --host 0.0.0.0, 编排时需使用 host 网络, 见 examples/)
FROM mcr.microsoft.com/devcontainers/universal:6-noble

# ---------------------------------------------------------------------------
# 运行时用户
# universal 6.x 的用户是 codespace、旧版 2.x 是 vscode, 均为 uid 1000;
# 找不到 uid 1000 用户时兜底创建 dsh 用户。用户名写入 /etc/dsh-container-user。
# ---------------------------------------------------------------------------
RUN set -eux; \
    if id 1000 >/dev/null 2>&1; then \
        getent passwd 1000 | cut -d: -f1 > /etc/dsh-container-user; \
    else \
        useradd -m -u 1000 -s /bin/bash dsh; \
        echo dsh > /etc/dsh-container-user; \
    fi

# dsh 数据目录(profiles / sessions / 插件)与默认工作区, 归运行时用户所有
RUN mkdir -p /dsh /workspace && chown 1000:1000 /dsh /workspace

ENV DSH_HOME=/dsh \
    DSH_AUTO_UPDATE=1 \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo

# ---------------------------------------------------------------------------
# 场景开发环境补装
# universal 镜像未包含 Rust/cargo 与 uv; 按场景需求补齐。
# 安装到 /usr/local(而非 /root), 保证运行时用户(uid 1000)可用。
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path; \
    for b in /usr/local/cargo/bin/*; do ln -s "$b" /usr/local/bin/; done; \
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; \
    rustc --version; \
    cargo --version; \
    uv --version

# ---------------------------------------------------------------------------
# 安装 dsh(官方 README 的 npm 方式: 安装 Node.js 后 npm/npx 安装 @deepseek-ai/dsh)
# 可传构建参数固定版本, 例如: --build-arg DSH_VERSION=0.1.0-rc.6
# 不指定时安装 npm 上最新版; 运行时仍可自动更新(container/dsh-update.sh)。
# npm 全局目录 chown 给 uid 1000, 使容器内的 dsh 自动更新无需 root。
# ---------------------------------------------------------------------------
ARG DSH_VERSION=latest
RUN set -eux; \
    NPM_PREFIX="$(npm prefix -g)"; \
    npm install --global --no-fund --no-audit "@deepseek-ai/dsh@${DSH_VERSION}"; \
    case "$NPM_PREFIX" in \
      /usr/local|/usr) echo "WARN: npm prefix $NPM_PREFIX left root-owned" ;; \
      *) chown -R 1000:1000 "$NPM_PREFIX" ;; \
    esac; \
    dsh --version

# 入口与更新脚本
COPY container/entrypoint.sh container/dsh-update.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/dsh-update.sh

WORKDIR /workspace
EXPOSE 3080

USER 1000
ENTRYPOINT ["entrypoint.sh"]
