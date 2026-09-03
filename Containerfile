# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh) 容器镜像
#
# 基础镜像: debian:13-slim —— 比通用开发容器镜像小很多, 只保留本项目
# 需要的工具链: Node.js LTS、pnpm、uv、Rust/cargo、Caddy、podman、gh。
# 在此之上按官方仓库 https://github.com/deepseek-ai/deepseek-harness 的源码
# 方式构建 dsh: git clone 后切换到指定 tag, 再用 pnpm install/build:official。
#
# 可复现性: 基础镜像 tag、rust 工具链、uv 版本、dsh 源码 tag 均可通过构建参数固定;
# pnpm 版本从所构建 tag 的 packageManager 读取并安装到系统层。Caddy/podman 来自
# apt 仓库, dsh 依赖树由官方 pnpm-lock.yaml 锁定, 默认构建安装官方最新 tag。
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
#   - 分层(hermes-agent 模式): 工具链全部是镜像所有的系统层真二进制 —— uv/pnpm
#     与 rustup 代理在 /usr/local/bin、rust 工具链树在 /opt/rust、dsh 在
#     /opt/deepseek-harness, 随镜像更新整体重置; /home/dsh 整体挂载为数据卷,
#     但卷上只有数据: ~/.dsh、可写缓存(~/.cargo 的 registry/cache、uv 的
#     ~/.local/share/uv、pnpm store)与用户自装工具(~/.local/bin、~/.cargo/bin,
#     PATH 垫底)。旧镜像种进卷的工具副本被 PATH 遮蔽(惰性), 手动清理见
#     release notes
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
ARG UV_VERSION=latest
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
# 工具链归镜像(系统层, 运行期只读), 卷只放可写缓存/数据/自装工具:
# RUSTUP_HOME 指向 /opt/rust 的工具链树; CARGO_HOME/PNPM_HOME 留在用户卷。
# PATH 镜像优先, 用户目录(含 PNPM_HOME 的自装全局包)垫底。
ENV DEBIAN_FRONTEND=noninteractive \
    SHELL=/bin/bash \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/home/dsh/.cargo \
    PNPM_HOME=/home/dsh/.local/share/pnpm \
    NPM_CONFIG_PREFIX=/home/dsh/.local
ENV PATH=/usr/local/sbin:/usr/local/bin:/home/dsh/.local/bin:/home/dsh/.cargo/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PNPM_HOME}

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
# 5. 安装 uv(系统层真二进制: 直接落 /usr/local/bin, 随镜像升级; 官方独立
#    安装脚本, 与 rustup 同模式)。UV_UNMANAGED_INSTALL 让脚本只落二进制、
#    不改 PATH/env 文件; astral.sh/uv/latest/install.sh 不存在(404),
#    latest 用默认 URL
# ---------------------------------------------------------------------------
RUN set -eux; \
    export UV_UNMANAGED_INSTALL=/usr/local/bin; \
    if [ "${UV_VERSION}" = "latest" ]; then \
      UV_URL="https://astral.sh/uv/install.sh"; \
    else \
      UV_URL="https://astral.sh/uv/${UV_VERSION}/install.sh"; \
    fi; \
    # astral.sh 的安装 URL 会 302 跳转, 必须带 -L 跟随, 否则存下的是 HTML 跳转页
    curl -sSfL --proto '=https' --tlsv1.2 "$UV_URL" -o /tmp/uv-install.sh; \
    sh /tmp/uv-install.sh; \
    rm -f /tmp/uv-install.sh; \
    uv --version

# ---------------------------------------------------------------------------
# 6. 安装 Rust/cargo(系统层: 工具链树在 /opt/rust, rustup 代理 symlink 到
#    /usr/local/bin, 随镜像升级)。运行期 RUSTUP_HOME 指回 /opt/rust/rustup
#    (只读), CARGO_HOME 重定向到用户卷(~/.cargo)承接 registry/cache 与
#    cargo install 自装工具 —— 工具链归镜像, 缓存/自装归用户
# ---------------------------------------------------------------------------
RUN set -eux; \
    export RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --profile minimal --no-modify-path --default-toolchain "${RUST_TOOLCHAIN}"; \
    for b in "$CARGO_HOME/bin/"*; do ln -sfn "$b" /usr/local/bin/; done; \
    rm -f /tmp/rustup-init.sh; \
    rustc --version; \
    cargo --version; \
    rustup --version

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
# 9. 安装 pnpm(系统层真二进制: npm 默认 prefix /usr/local, 随镜像升级;
#    版本仍从所构建 tag 的 packageManager 读取, 与 dsh 锁文件的契约一致)。
#    显式 --prefix 压过 ENV 里的 NPM_CONFIG_PREFIX(那是给运行期用户的)。
#    PNPM_HOME 留在用户卷, 只承接 pnpm store 与用户自装全局包
# ---------------------------------------------------------------------------
RUN set -eux; \
    PNPM_VERSION="$(node -p "require('/opt/deepseek-harness/package.json').packageManager.split('@')[1]")"; \
    npm install --global --prefix /usr/local --no-fund --no-audit "pnpm@$PNPM_VERSION"; \
    pnpm --version

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
    jq -n --arg version "${BUILD_VERSION}" --arg dsh_tag "${DSH_TAG}" \
          --arg revision "${BUILD_GIT_SHA}" \
          --arg node "$(node --version)" --arg pnpm "$(pnpm --version)" \
          --arg rust "$(rustc --version | awk '{print $2}')" \
          --arg uv "$(uv --version | awk '{print $2}')" \
      '{schema:1,image:"ghcr.io/niyueee/dsh-container",version:$version,dsh_tag:$dsh_tag,revision:$revision,tools:{node:$node,pnpm:$pnpm,rust:$rust,uv:$uv}}' \
      > /etc/dsh-container/provenance.json; \
    chmod 0444 /etc/dsh-container/provenance.json; \
    cat /etc/dsh-container/provenance.json; \
    dsh --version

# ---------------------------------------------------------------------------
# 11. 预热 apt 包索引: 最终镜像保留一份最新 /var/lib/apt/lists, 容器内开箱
#     即可 apt install, 无需先手动 apt-get update。前面各步骤用完即清是为了
#     压缩中间层; 这里的索引属于系统层, 随镜像升级重置
# ---------------------------------------------------------------------------
RUN apt-get update

# ---------------------------------------------------------------------------
# 12. 运行配置
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
