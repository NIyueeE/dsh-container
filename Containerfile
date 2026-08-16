# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh) 容器镜像
#
# 基础镜像: mcr.microsoft.com/devcontainers/universal —— 微软通用开发容器
# (体积大但开箱即用, 自带 Node.js/nvm、Python、Go、Java、Docker CLI 等工具链)。
# 在此之上补装 Rust/cargo 与 uv, 并按官方仓库
# https://github.com/deepseek-ai/deepseek-harness 介绍的 npm 方式安装 dsh。
#
# 可复现性: 基础镜像 tag、rust 工具链、dsh 顶层版本均可通过构建参数固定;
# rustup/uv/pnpm 按官方脚本安装, 版本不固定(用户级工具, 随 /home/codespace
# 数据卷持久化, 可由用户自行更新)。Caddy/podman 来自 apt 仓库, npm 全局安装
# 没有 lockfile, 因此默认构建不是逐字节可复现, 生产发布建议固定 DSH_VERSION:
#   podman build --format docker \
#                --build-arg DSH_VERSION=0.1.0-rc.6 \
#                --build-arg RUST_TOOLCHAIN=1.88.0 \
#                -t dsh-container .
# --format docker 不能省略: podman 默认 OCI 格式会丢弃 HEALTHCHECK。
# BUILD_VERSION 写入 OCI 版本 label: CI 打 v* tag 时传 release 版本(如 1.2.0),
# 与镜像 tag 对齐; 未传时默认 latest。
#
# 运行时行为由 container/entrypoint.sh 控制:
#   - dsh 数据目录使用上游默认 ~/.dsh(即 /home/codespace/.dsh), 不设 DSH_HOME;
#     进程 cwd 直接使用 $HOME, 不预创建固定工作区子目录
#   - dsh web 由 dsh-web 守护脚本托管, 崩溃/退出后自动重启;
#     容器内可用 dsh-restart 手动重启 dsh web(无需重启整个容器)
#   - 持久化策略: 把整个 /home/codespace 挂载为数据卷, 用户态工具/缓存/配置
#     都保留; 系统层(/usr/local、apt 包)随镜像更新重置。Rust/cargo、uv、pnpm
#     均安装为 codespace 用户级工具: ~/.rustup + ~/.cargo、~/.local、~/.local/share/pnpm
#   - 启动时默认不自动更新 dsh(DSH_AUTO_UPDATE=0, 镜像 tag 决定版本);
#     显式设置 DSH_AUTO_UPDATE=1 时启动时更新到 npm latest(只升不降)
#   - 随后以 `dsh web` 启动 Web UI, 监听 127.0.0.1:3080
#     (npm 发布版与上游 main 均拒绝 --host 0.0.0.0: 上游有意为之的安全设计)
#   - Caddy 反向代理监听 0.0.0.0:3081, 把 Host/Origin 改写为回环后转发到 dsh 的
#     127.0.0.1:3080, 并对 UI 资源做 gzip 压缩(远端访问更快); 运行期崩溃自动重启。
#     dsh 的 /api 信任围栏只检查 HTTP 头, 因此远程浏览器经代理
#     也能通过全部接口(含设置/凭据等原本仅回环的方法); 安全边界随之转移到代理。
#     DSH_PROXY_USER + DSH_PROXY_PASSWORD 必须成对设置以启用 basic auth,
#     只设置一个会直接拒绝启动, 见 docs/security.md

# ---- 构建参数(全部有默认值) ----------------------------------------------
# BASE_IMAGE 声明在 FROM 之前(全局作用域), 供 FROM 行使用; 其余 ARG 在 FROM
# 之后重新声明才对本阶段可见。基础镜像默认固定 6.1.1-noble, 与 examples 中
# 的 /home/codespace 用户层约定一致; 可用 BASE_IMAGE 覆盖。
ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/universal:6.1.1-noble

FROM ${BASE_IMAGE}

ARG DSH_VERSION=latest
ARG BUILD_VERSION=latest
ARG RUST_TOOLCHAIN=stable
ARG BUILD_GIT_SHA=unknown
ARG BUILD_GIT_REF=unknown

LABEL org.opencontainers.image.title="DeepSeek Harness (dsh) container image" \
      org.opencontainers.image.description="Universal dev-container based image for the DeepSeek Harness Web UI, with optional dsh auto-update on boot" \
      org.opencontainers.image.source="https://github.com/niyueee/dsh-container" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_GIT_SHA}" \
      org.opencontainers.image.ref.name="${BUILD_GIT_REF}"

# ---------------------------------------------------------------------------
# 运行时用户: 基础镜像固定为 universal 6.1.1-noble, 用户是 codespace(uid 1000)。
# ---------------------------------------------------------------------------

# 用户层状态目录: 整个 home 会被数据卷持久化, 这里预创建默认目录并归运行时
# 用户所有。dsh 数据用上游默认 ~/.dsh, cargo 缓存用默认 ~/.cargo; 不预创建
# 固定工作区, dsh 运行时直接以 $HOME 为 cwd 并按需创建目录。
RUN set -eux; \
    mkdir -p /home/codespace/.dsh /home/codespace/.cargo \
             /home/codespace/.local/bin /home/codespace/.local/share/pnpm; \
    chown -R 1000:1000 /home/codespace/.dsh /home/codespace/.cargo /home/codespace/.local

# Caddy: 轻量反向代理(npm 发布版与上游 main 的 dsh 均拒绝 --host 0.0.0.0,
# 由 entrypoint 用 Caddy 监听 0.0.0.0:3081, 把 Host/Origin 改写为回环后
# 转发到 127.0.0.1:3080, gzip 压缩 UI 资源并可选启用 basicauth; 运行期
# 崩溃由 entrypoint 守护自动重启)。
# 注意: 发行版 caddy 2.6 的 Caddyfile 认证指令是 basicauth(2.7 起才叫 basic_auth)。
# podman 作为容器内 rootless 容器开发工具; 同时安装 rootless 网络/存储依赖,
# 并为运行时用户写入 subuid/subgid 映射。宿主运行时是否允许嵌套用户命名空间
# 取决于 Docker/Podman 的 seccomp/userns 配置, 见 docs/security.md。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends caddy; \
    apt-get install -y podman fuse-overlayfs; \
    rm -rf /var/lib/apt/lists/*; \
    touch /etc/subuid /etc/subgid; \
    if ! grep -q '^codespace:' /etc/subuid; then \
        usermod --add-subuids 100000-165535 --add-subgids 100000-165535 codespace; \
    fi; \
    podman --version

# 用户级工具目录: Rust/cargo、pnpm 都放在 /home/codespace 的持久化用户层。
# 这些 ENV 只是工具自身的默认值, 不属于对用户暴露的 dsh 配置面。
# DSH_AUTO_UPDATE 默认 0: 镜像 tag 决定 dsh 版本; 需要启动时追 npm latest 才设 1。
ENV DSH_AUTO_UPDATE=0 \
    RUSTUP_HOME=/home/codespace/.rustup \
    CARGO_HOME=/home/codespace/.cargo \
    PNPM_HOME=/home/codespace/.local/share/pnpm

# ---------------------------------------------------------------------------
# Node.js: 使用 universal 自带 nvm 安装最新 LTS(稳定版), 作为系统层运行时。
# ---------------------------------------------------------------------------
RUN set -eux; \
    export NVM_DIR=/usr/local/share/nvm; \
    . "$NVM_DIR/nvm.sh"; \
    nvm install --lts --no-progress; \
    nvm alias default 'lts/*'; \
    node --version; \
    npm --version

# ---------------------------------------------------------------------------
# pnpm: 通过 npm 安装到用户级 PNPM_HOME, 再把 bin 链到 ~/.local/bin 和
# /usr/local/bin(后者让 docker exec 等不经过 entrypoint 的进程也能找到)。
# ---------------------------------------------------------------------------
RUN set -eux; \
    USER_HOME=/home/codespace; \
    PNPM_HOME="$USER_HOME/.local/share/pnpm"; \
    USER_BIN="$USER_HOME/.local/bin"; \
    mkdir -p "$PNPM_HOME" "$USER_BIN"; \
    npm install --global --prefix "$PNPM_HOME" --no-fund --no-audit pnpm; \
    ln -sfn "$PNPM_HOME/bin/pnpm" "$USER_BIN/pnpm"; \
    ln -sfn "$USER_BIN/pnpm" /usr/local/bin/pnpm; \
    chown -R 1000:1000 "$USER_HOME/.local"; \
    HOME="$USER_HOME" PNPM_HOME="$PNPM_HOME" pnpm --version

# ---------------------------------------------------------------------------
# Rust/cargo: 官方 rustup 脚本, 工具链与 cargo home 都在用户目录。
# 通过 /usr/local/bin 建立系统层符号链接, 保证 docker exec 也可直接用。
# ---------------------------------------------------------------------------
RUN set -eux; \
    USER_HOME=/home/codespace; \
    export HOME="$USER_HOME"; \
    export RUSTUP_HOME="$USER_HOME/.rustup"; \
    export CARGO_HOME="$USER_HOME/.cargo"; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    bash -o pipefail -c \
        'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path --default-toolchain "${RUST_TOOLCHAIN}"'; \
    for b in "$CARGO_HOME/bin/"*; do ln -sfn "$b" /usr/local/bin/; done; \
    chown -R 1000:1000 "$RUSTUP_HOME" "$CARGO_HOME"; \
    rustc --version; \
    cargo --version

# ---------------------------------------------------------------------------
# uv: 官方安装脚本, 二进制放 ~/.local/bin; Python/tool 数据使用 uv 默认的
# ~/.local/share/uv 与 ~/.cache/uv(当前 uv 0.x 没有统一的 UV_HOME 变量)。
# ---------------------------------------------------------------------------
RUN set -eux; \
    USER_HOME=/home/codespace; \
    USER_BIN="$USER_HOME/.local/bin"; \
    mkdir -p "$USER_BIN"; \
    HOME="$USER_HOME" UV_INSTALL_DIR="$USER_BIN" \
        bash -o pipefail -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'; \
    ln -sfn "$USER_BIN/uv" /usr/local/bin/uv; \
    ln -sfn "$USER_BIN/uvx" /usr/local/bin/uvx; \
    chown -R 1000:1000 "$USER_HOME/.local"; \
    HOME="$USER_HOME" uv --version

# ---------------------------------------------------------------------------
# 安装 dsh(官方 README 的 npm 方式: 安装 Node.js 后 npm/npx 安装 @deepseek-ai/dsh)
# 不指定 DSH_VERSION 时安装 npm 最新版。运行时默认不自动更新(DSH_AUTO_UPDATE=0);
# 显式设置 DSH_AUTO_UPDATE=1 时由 container/dsh-update.sh 在启动时更新。
# npm 全局目录 chown 给 uid 1000, 使自动更新无需 root。
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.npm,id=npm-${DSH_VERSION} \
    set -eux; \
    NPM_PREFIX="$(npm prefix -g)"; \
    # --dangerously-allow-all-scripts: npm 11.16+ 的 allow-scripts 机制默认
    # 放行未审批脚本, 但未来 npm 可能默认收紧(approve-scripts 明确不支持
    # 全局安装, 报 EGLOBAL)。显式声明允许执行 install scripts(原生模块
    # node-pty/koffi 等依赖), 使构建期与容器内运行时(uid 1000, 无 root)
    # 的 dsh 自动更新行为一致, 不因审批策略静默产出原生模块缺失的坏安装。
    npm install --global --no-fund --no-audit --dangerously-allow-all-scripts "@deepseek-ai/dsh@${DSH_VERSION}"; \
    case "$NPM_PREFIX" in \
      /usr/local|/usr) echo "WARN: npm prefix $NPM_PREFIX left root-owned" ;; \
      *) chown -R 1000:1000 "$NPM_PREFIX" ;; \
    esac; \
    dsh --version

# 入口、更新与 dsh web 守护/重启脚本: 安装时去掉 .sh 扩展名
# (容器内命令名为 entrypoint / dsh-update / dsh-web / dsh-restart)
# 显式 755: 源文件权限可能不完整, 运行时用户必须可读可执行。
COPY container/entrypoint.sh /usr/local/bin/entrypoint
COPY container/dsh-update.sh /usr/local/bin/dsh-update
COPY container/dsh-web.sh /usr/local/bin/dsh-web
COPY container/dsh-restart.sh /usr/local/bin/dsh-restart
RUN chmod 755 /usr/local/bin/entrypoint /usr/local/bin/dsh-update /usr/local/bin/dsh-web /usr/local/bin/dsh-restart

# WORKDIR 仅作 docker exec 等场景的兜底(entrypoint 总会 cd 到 $HOME)。
WORKDIR /
EXPOSE 3081

# Caddy 把 0.0.0.0:3081 改写头后转发到 dsh 的 127.0.0.1:3080(桥接 + 端口映射
# 下即宿主 127.0.0.1:3081); universal 自带 curl。健康检查: dsh 直接可达
# (127.0.0.1:3080)且代理有响应即可 —— 代理路径不要求 200, 因为启用 basic auth
# 时未带凭据的请求是 401, 但代理本身存活。
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3080/ >/dev/null && curl -sS -o /dev/null http://127.0.0.1:3081/ >/dev/null || exit 1

USER 1000
ENTRYPOINT ["entrypoint"]
