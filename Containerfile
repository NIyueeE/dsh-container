# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh) 容器镜像
#
# 基础镜像: mcr.microsoft.com/devcontainers/universal —— 微软通用开发容器
# (体积大但开箱即用, 自带 Node.js/nvm、Python、Go、Java、Docker CLI 等工具链)。
# 在此之上补装 Rust/cargo 与 uv, 并按官方仓库
# https://github.com/deepseek-ai/deepseek-harness 介绍的 npm 方式安装 dsh。
#
# 可复现性: 基础镜像 tag、uv、rust 工具链、dsh 版本全部支持构建参数固定
# (CI 只传 BUILD_GIT_SHA/REF, 其余用默认值):
#   podman build --build-arg BASE_IMAGE=mcr.microsoft.com/devcontainers/universal:6.1.1-noble \
#                --build-arg DSH_VERSION=0.1.0-rc.6 \
#                --build-arg RUST_TOOLCHAIN=1.88.0 \
#                --build-arg UV_VERSION=0.12.3 \
#                -t dsh-container .
#
# 运行时行为由 container/entrypoint.sh 控制:
#   - 启动时自动把 dsh 更新到 npm 最新版(DSH_AUTO_UPDATE=1, 默认开启)
#   - 随后以 `dsh web` 启动 Web UI, 默认监听 127.0.0.1:3080
#     (dsh 出于安全考虑拒绝 --host 0.0.0.0, 编排时需使用 host 网络, 见 examples/)

# ---- 构建参数(全部有默认值, 无硬编码) ------------------------------------
# BASE_IMAGE 必须声明在 FROM 之前; 其余 ARG 在 FROM 之后重新声明才对本阶段可见。
ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/universal:6-noble

FROM ${BASE_IMAGE}

ARG DSH_VERSION=latest
ARG RUST_TOOLCHAIN=stable
ARG UV_VERSION=0.12.3
ARG BUILD_GIT_SHA=unknown
ARG BUILD_GIT_REF=unknown

LABEL org.opencontainers.image.title="DeepSeek Harness (dsh) container image" \
      org.opencontainers.image.description="Universal dev-container based image for the DeepSeek Harness Web UI, with dsh auto-update on boot" \
      org.opencontainers.image.source="https://github.com/niyueee/dsh-container" \
      org.opencontainers.image.version="${DSH_VERSION}" \
      org.opencontainers.image.revision="${BUILD_GIT_SHA}"

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
# uv 直接从官方镜像 COPY 固定版本(比 curl|sh 更可复现、更快);
# rustup 安装固定工具链。均装在 /usr/local, 运行时用户(uid 1000)可用。
# 缓存挂载按版本参数区分 id, 避免不同版本共享同一份缓存。
# ---------------------------------------------------------------------------
COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /uvx /bin/

RUN --mount=type=cache,target=/usr/local/rustup,id=rustup-${RUST_TOOLCHAIN} \
    --mount=type=cache,target=/usr/local/cargo,id=cargo-${RUST_TOOLCHAIN} \
    set -eux; \
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path \
        --default-toolchain "${RUST_TOOLCHAIN}"; \
    for b in /usr/local/cargo/bin/*; do ln -s "$b" /usr/local/bin/; done; \
    rustc --version; \
    cargo --version; \
    uv --version

# ---------------------------------------------------------------------------
# 安装 dsh(官方 README 的 npm 方式: 安装 Node.js 后 npm/npx 安装 @deepseek-ai/dsh)
# 不指定 DSH_VERSION 时安装 npm 最新版; 运行时仍可自动更新(container/dsh-update.sh),
# 离线/可复现部署可用 DSH_VERSION 固定 + 运行时 DSH_AUTO_UPDATE=0。
# npm 全局目录 chown 给 uid 1000, 使容器内的 dsh 自动更新无需 root。
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.npm,id=npm-${DSH_VERSION} \
    set -eux; \
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

# dsh web 监听 127.0.0.1:3080(host 网络下即宿主机地址); universal 自带 curl。
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3080/ >/dev/null || exit 1

USER 1000
ENTRYPOINT ["entrypoint.sh"]
