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
# (CI 只传 BUILD_GIT_SHA/REF、BUILD_VERSION, 其余用默认值):
#   podman build --build-arg BASE_IMAGE=mcr.microsoft.com/devcontainers/universal:6.1.1-noble \
#                --build-arg DSH_VERSION=0.1.0-rc.6 \
#                --build-arg RUST_TOOLCHAIN=1.88.0 \
#                --build-arg UV_VERSION=0.12.3 \
#                -t dsh-container .
# BUILD_VERSION 写入 OCI 版本 label: CI 打 v* tag 时传 release 版本(如 1.2.0),
# 与镜像 tag 对齐; 未传时默认 latest。
#
# 运行时行为由 container/entrypoint.sh 控制:
#   - 启动时自动把 dsh 更新到 npm 最新版(DSH_AUTO_UPDATE=1, 默认开启)
#   - 随后以 `dsh web --host $DSH_WEB_HOST` 启动 Web UI, 默认监听 0.0.0.0:3080
#     (上游 dsh 默认仅监听 127.0.0.1, 本镜像默认 0.0.0.0 以配合桥接+端口映射;
#      设 DSH_WEB_HOST=127.0.0.1 可恢复仅回环, 见 examples/)

# ---- 构建参数(全部有默认值, 无硬编码) ------------------------------------
# BASE_IMAGE / UV_VERSION 声明在 FROM 之前(全局作用域), 供 FROM 行使用;
# 其余 ARG 在 FROM 之后重新声明才对本阶段可见。
# 默认 latest(当前与 6.1.1-noble 同 digest); 需要可复现构建时固定精确 tag, 例如:
#   --build-arg BASE_IMAGE=mcr.microsoft.com/devcontainers/universal:6.1.1-noble
ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/universal:latest
ARG UV_VERSION=0.12.3

# uv 固定版本: BuildKit 不支持 COPY --from 里的变量展开, 用独立 stage 规避
# (FROM 行支持全局 ARG 展开)。
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-stage

FROM ${BASE_IMAGE}

ARG DSH_VERSION=latest
ARG BUILD_VERSION=latest
ARG RUST_TOOLCHAIN=stable
ARG UV_VERSION=0.12.3
ARG BUILD_GIT_SHA=unknown
ARG BUILD_GIT_REF=unknown

LABEL org.opencontainers.image.title="DeepSeek Harness (dsh) container image" \
      org.opencontainers.image.description="Universal dev-container based image for the DeepSeek Harness Web UI, with dsh auto-update on boot" \
      org.opencontainers.image.source="https://github.com/niyueee/dsh-container" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
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
    DSH_WEB_HOST=0.0.0.0 \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo

# ---------------------------------------------------------------------------
# 场景开发环境补装
# universal 镜像未包含 Rust/cargo 与 uv; 按场景需求补齐。
# uv 从上面的 uv-stage COPY 固定版本(比 curl|sh 更可复现、更快)。
# rustup 安装固定工具链: 注意 --mount=type=cache 的内容不会进入镜像层,
# 因此缓存挂载放在独立的 /opt 缓存目录, 装完后 cp -a 拷回 /usr/local
# (真实镜像层), 再建 /usr/local/bin 符号链接供运行时用户(uid 1000)使用。
# ---------------------------------------------------------------------------
COPY --from=uv-stage /uv /uvx /bin/

RUN --mount=type=cache,target=/opt/rustup-cache,id=rustup-${RUST_TOOLCHAIN} \
    --mount=type=cache,target=/opt/cargo-cache,id=cargo-${RUST_TOOLCHAIN} \
    set -eux; \
    mkdir -p /usr/local/rustup /usr/local/cargo; \
    RUSTUP_HOME=/opt/rustup-cache CARGO_HOME=/opt/cargo-cache \
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal \
            --no-modify-path --default-toolchain "${RUST_TOOLCHAIN}"; \
    cp -a /opt/rustup-cache/. /usr/local/rustup/; \
    cp -a /opt/cargo-cache/. /usr/local/cargo/; \
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
    # npm 11.16+ 的 allow-scripts 机制: 显式批准全部 install scripts,
    # 固化允许列表(原生模块 node-pty/koffi 等依赖这些脚本), 也保证
    # 容器内运行时 dsh 自动更新时脚本能正常执行。
    npm approve-scripts --all >/dev/null 2>&1 || true; \
    case "$NPM_PREFIX" in \
      /usr/local|/usr) echo "WARN: npm prefix $NPM_PREFIX left root-owned" ;; \
      *) chown -R 1000:1000 "$NPM_PREFIX" ;; \
    esac; \
    dsh --version

# 入口与更新脚本: 安装时去掉 .sh 扩展名(容器内命令名为 entrypoint / dsh-update)
# 显式 755: 源文件权限可能不完整, 运行时用户必须可读可执行。
COPY container/entrypoint.sh /usr/local/bin/entrypoint
COPY container/dsh-update.sh /usr/local/bin/dsh-update
RUN chmod 755 /usr/local/bin/entrypoint /usr/local/bin/dsh-update

WORKDIR /workspace
EXPOSE 3080

# dsh web 监听 0.0.0.0:3080(桥接 + 端口映射下即宿主 127.0.0.1:3080); universal 自带 curl。
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3080/ >/dev/null || exit 1

USER 1000
ENTRYPOINT ["entrypoint"]
