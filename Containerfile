# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh) 容器镜像
#
# 基础镜像: debian:13-slim —— 比通用开发容器镜像小很多, 只保留本项目
# 需要的工具链: Node.js LTS、pnpm、uv、Rust/cargo、Caddy、podman、gh。
# 在此之上按官方仓库 https://github.com/deepseek-ai/deepseek-harness 的源码
# 方式构建 dsh: git clone 后切换到指定 tag, 再用 pnpm install/build:official。
#
# 可复现性: 基础镜像 tag、rust 工具链、dsh 源码 tag 均可通过构建参数固定;
# pnpm 版本从所构建 tag 的 packageManager 读取并安装为用户级工具
# (随 /home/dsh 数据卷持久化, 可由用户自行更新)。Caddy/podman 来自 apt 仓库,
# dsh 依赖树由官方 pnpm-lock.yaml 锁定, 默认构建安装官方最新 tag。
# 生产发布建议固定 DSH_TAG:
#   podman build --format docker \
#                --build-arg DSH_TAG=dsh-v0.1.2-alpha.4 \
#                --build-arg RUST_TOOLCHAIN=1.88.0 \
#                -t dsh-container .
# BUILD_VERSION 写入 OCI 版本 label: CI 打 dsh-v* tag 时传官方仓库 tag,
# 与镜像 tag 对齐; 未传时默认 latest。
#
# 运行时行为由 container/entrypoint.sh 控制:
#   - dsh 数据目录使用上游默认 ~/.dsh(即 /home/dsh/.dsh), 不设 DSH_HOME;
#     进程 cwd 直接使用 $HOME, 不预创建固定工作区子目录
#   - dsh web 由 dsh-web 守护脚本托管, 崩溃/退出后自动重启;
#     容器内可用 dsh-restart 手动重启 dsh web(无需重启整个容器)
#   - dsh-web 每次启动 dsh web 前会运行 dsh-client-patch: 上游浏览器端仍按
#     location.hostname 限制设置/凭据, 该补丁把经代理的远程浏览器视为回环并
#     注入 crypto.randomUUID polyfill(纯 HTTP 内网兼容); 幂等且版本漂移时
#     警告跳过
#   - 持久化策略: 把整个 /home/dsh 挂载为数据卷, 用户态工具/缓存/配置
#     都保留; 系统层(/usr/local、/opt、apt 包)随镜像更新重置。Rust/cargo、uv、
#     pnpm 安装为 dsh 用户级工具: ~/.rustup + ~/.cargo、~/.local、~/.local/share/pnpm;
#     dsh 源码与构建产物在系统层 /opt/deepseek-harness, 不依赖用户数据卷
#   - 随后以 `dsh web` 启动 Web UI, 监听 127.0.0.1:3080
#     (上游 tag 与 main 均拒绝 --host 0.0.0.0: 上游有意为之的安全设计)
#   - Caddy 反向代理监听 0.0.0.0:3081, 把 Host/Origin 改写为回环后转发到 dsh 的
#     127.0.0.1:3080, 并对 UI 资源做 gzip 压缩(远端访问更快); 运行期崩溃自动重启。
#     dsh 的 /api 信任围栏只检查 HTTP 头, 因此远程浏览器经代理
#     也能通过全部接口(含设置/凭据等原本仅回环的方法); 安全边界随之转移到代理。
#     DSH_PROXY_USER + DSH_PROXY_PASSWORD 必须成对设置以启用 basic auth,
#     只设置一个会直接拒绝启动, 见 docs/security.md

# ---- 构建参数(全部有默认值) ----------------------------------------------
# BASE_IMAGE 声明在 FROM 之前(全局作用域), 供 FROM 行使用; 其余 ARG 在 FROM
# 之后重新声明才对本阶段可见。
ARG BASE_IMAGE=debian:13-slim

FROM ${BASE_IMAGE}

ARG DSH_TAG=latest
ARG BUILD_VERSION=latest
ARG RUST_TOOLCHAIN=stable
ARG BUILD_GIT_SHA=unknown
ARG BUILD_GIT_REF=unknown
ARG USERNAME=dsh
ARG USER_UID=1000
ARG USER_GID=1000

LABEL org.opencontainers.image.title="DeepSeek Harness (dsh) container image" \
      org.opencontainers.image.description="Debian slim based image for the DeepSeek Harness Web UI, built from source at a pinned upstream tag" \
      org.opencontainers.image.source="https://github.com/niyueee/dsh-container" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_GIT_SHA}" \
      org.opencontainers.image.ref.name="${BUILD_GIT_REF}"

# 基础环境变量
ENV DEBIAN_FRONTEND=noninteractive \
    SHELL=/bin/bash \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RUSTUP_HOME=/home/dsh/.rustup \
    CARGO_HOME=/home/dsh/.cargo \
    PNPM_HOME=/home/dsh/.local/share/pnpm \
    NPM_CONFIG_PREFIX=/home/dsh/.local \
    PATH=/usr/local/sbin:/usr/local/bin:/home/dsh/.local/bin:/home/dsh/.cargo/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------------------------------------------------------------------------
# 1. 安装基础工具链、C/C++ 编译依赖、Caddy、嵌套 Podman 及 GitHub CLI 源
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    git \
    build-essential \
    pkg-config \
    libssl-dev \
    sudo \
    jq \
    unzip \
    procps \
    caddy \
    podman \
    fuse-overlayfs \
    uidmap \
    slirp4netns \
    iptables \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. 创建 dsh 用户、免密 sudo 组、rootless Podman 映射
# ---------------------------------------------------------------------------
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && usermod -aG sudo $USERNAME \
    && echo '%sudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME \
    && echo "$USERNAME:100000:65536" >> /etc/subuid \
    && echo "$USERNAME:100000:65536" >> /etc/subgid \
    && mkdir -p /home/dsh/.dsh /home/dsh/.cargo /home/dsh/.local/bin /home/dsh/.local/share/pnpm \
    && chown -R $USER_UID:$USER_GID /home/dsh/.dsh /home/dsh/.cargo /home/dsh/.local

# ---------------------------------------------------------------------------
# 3. 配置嵌套 Podman(fuse-overlayfs + 宽松 policy)
# ---------------------------------------------------------------------------
RUN mkdir -p /etc/containers \
    && if [ -f /etc/containers/storage.conf ]; then \
         sed -i \
           -e 's|^#mount_program|mount_program|' \
           -e 's|^mount_program.*|mount_program = "/usr/bin/fuse-overlayfs"|' \
           /etc/containers/storage.conf; \
       else \
         printf '[storage]\ndriver = "overlay"\n\n[storage.options]\nmount_program = "/usr/bin/fuse-overlayfs"\n' \
           > /etc/containers/storage.conf; \
       fi \
    && echo '{"default": [{"type": "insecureAcceptAnything"}]}' > /etc/containers/policy.json

# ---------------------------------------------------------------------------
# 4. 安装 Node.js 22.x LTS(系统层)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/node-setup.sh \
    && bash /tmp/node-setup.sh \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* /tmp/node-setup.sh

# ---------------------------------------------------------------------------
# 5. 安装 uv(用户级, 持久化在 /home/dsh/.local)
# ---------------------------------------------------------------------------
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /uvx /home/dsh/.local/bin/
RUN ln -sfn /home/dsh/.local/bin/uv /usr/local/bin/uv \
    && ln -sfn /home/dsh/.local/bin/uvx /usr/local/bin/uvx \
    && chown -R dsh:dsh /home/dsh/.local

# ---------------------------------------------------------------------------
# 6. 安装 Rust/cargo(用户级)
# ---------------------------------------------------------------------------
RUN set -eux; \
    USER_HOME=/home/dsh; \
    export HOME="$USER_HOME"; \
    export RUSTUP_HOME="$USER_HOME/.rustup"; \
    export CARGO_HOME="$USER_HOME/.cargo"; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --profile minimal --no-modify-path --default-toolchain "${RUST_TOOLCHAIN}"; \
    for b in "$CARGO_HOME/bin/"*; do ln -sfn "$b" /usr/local/bin/; done; \
    chown -R dsh:dsh "$RUSTUP_HOME" "$CARGO_HOME"; \
    rm -f /tmp/rustup-init.sh; \
    rustc --version; \
    cargo --version

# ---------------------------------------------------------------------------
# 7. 入口、dsh web 守护/重启与前端兼容补丁脚本
# ---------------------------------------------------------------------------
COPY container/entrypoint.sh /usr/local/bin/entrypoint
COPY container/dsh-web.sh /usr/local/bin/dsh-web
COPY container/dsh-restart.sh /usr/local/bin/dsh-restart
COPY container/dsh-client-patch.sh /usr/local/bin/dsh-client-patch
COPY container/dsh-migrate-legacy.sh /usr/local/bin/dsh-migrate-legacy
RUN chmod 755 /usr/local/bin/entrypoint /usr/local/bin/dsh-web /usr/local/bin/dsh-restart /usr/local/bin/dsh-client-patch /usr/local/bin/dsh-migrate-legacy

# ---------------------------------------------------------------------------
# 8. 拉取 dsh 官方源码并切换到指定 tag(默认 latest = 官方最新 tag)
# ---------------------------------------------------------------------------
RUN set -eux; \
    git clone --filter=blob:none --no-checkout https://github.com/deepseek-ai/deepseek-harness.git /opt/deepseek-harness; \
    cd /opt/deepseek-harness; \
    if [ "${DSH_TAG}" = "latest" ]; then \
      DSH_TAG="$(git tag --sort=-v:refname --list 'dsh-v*' | head -n1)"; \
      echo "resolved latest upstream dsh tag: $DSH_TAG"; \
    fi; \
    test -n "$DSH_TAG"; \
    git checkout "$DSH_TAG"; \
    git rev-parse HEAD

# ---------------------------------------------------------------------------
# 9. 安装 pnpm(用户级, 版本对齐所构建 tag 的 packageManager)
# ---------------------------------------------------------------------------
RUN set -eux; \
    USER_HOME=/home/dsh; \
    PNPM_HOME="$USER_HOME/.local/share/pnpm"; \
    USER_BIN="$USER_HOME/.local/bin"; \
    mkdir -p "$PNPM_HOME" "$USER_BIN"; \
    PNPM_VERSION="$(node -p "require('/opt/deepseek-harness/package.json').packageManager.split('@')[1]")"; \
    npm install --global --prefix "$PNPM_HOME" --no-fund --no-audit "pnpm@$PNPM_VERSION"; \
    ln -sfn "$PNPM_HOME/bin/pnpm" "$USER_BIN/pnpm"; \
    ln -sfn "$USER_BIN/pnpm" /usr/local/bin/pnpm; \
    chown -R dsh:dsh "$USER_HOME/.local"; \
    HOME="$USER_HOME" PNPM_HOME="$PNPM_HOME" "$PNPM_HOME/bin/pnpm" --version

# ---------------------------------------------------------------------------
# 10. 从源码构建 dsh(系统层 /opt/deepseek-harness; 构建产物与镜像绑定)
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.pnpm-store,id=pnpm-store \
    set -eux; \
    export CI=true; \
    cd /opt/deepseek-harness; \
    pnpm install --frozen-lockfile --store-dir /root/.pnpm-store; \
    pnpm run build:official; \
    ln -sfn /opt/deepseek-harness/apps/cli/lib/bin.js /usr/local/bin/dsh; \
    DSH_CLIENT_PATCH_ROOT=/opt/deepseek-harness dsh-client-patch; \
    chown -R dsh:dsh /opt/deepseek-harness; \
    mkdir -p /etc/dsh-container; \
    printf '{"schema":1,"image":"ghcr.io/niyueee/dsh-container","version":"%s","dsh_tag":"%s","revision":"%s"}\n' \
      "${BUILD_VERSION}" "${DSH_TAG}" "${BUILD_GIT_SHA}" > /etc/dsh-container/provenance.json; \
    chmod 0444 /etc/dsh-container/provenance.json; \
    cat /etc/dsh-container/provenance.json; \
    dsh --version

# ---------------------------------------------------------------------------
# 11. 运行配置
# ---------------------------------------------------------------------------
WORKDIR /home/dsh
EXPOSE 3081

# Caddy 把 0.0.0.0:3081 改写头后转发到 dsh 的 127.0.0.1:3080;
# healthcheck 同时要求 dsh 和代理可响应。dsh web 对无会话的根请求返回 401,
# 因此这里用 curl 的退出码(连接成功)而不是 HTTP 200 作为存活判据。
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sS -o /dev/null http://127.0.0.1:3080/ && curl -sS -o /dev/null http://127.0.0.1:3081/ || exit 1

USER dsh
ENTRYPOINT ["entrypoint"]
