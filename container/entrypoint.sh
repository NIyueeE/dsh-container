#!/usr/bin/env bash
# DeepSeek Harness 容器入口:
#   1. 还原 HOME(数值 USER 1000 不会自动设置)
#   2. 分层(hermes-agent 模式): 工具链全部是镜像所有的系统层真二进制 ——
#      dsh 本体 /opt/deepseek-harness、uv/pnpm/cargo 代理 /usr/local/bin、
#      rust 工具链树 /opt/rust, 随镜像更新整体重置; 数据卷(/home/dsh 整体
#      挂载)只放数据与缓存: dsh 数据 ~/.dsh(上游默认, 不设 DSH_HOME)、
#      CARGO_HOME=~/.cargo(registry/cache 与 cargo install 自装工具)、
#      uv/pnpm 数据 ~/.local/share/{uv,pnpm}。PATH 镜像优先(/usr/local/bin
#      最前), 卷上遗留的旧副本遮蔽不了镜像内版本(手动清理见 release notes)。
#   3. 解析 --port <N> / --port=<N>(默认 3080; 拒绝 0 与 3081), 经
#      DSH_WEB_PORT 传给 dsh-web(内部管道变量, 非用户配置面)。
#   4. 容器内 podman 运行期环境: provision XDG_RUNTIME_DIR(rootless podman
#      必须能写它; 容器无 login session, /run/user/$UID 默认不存在且 /run 属
#      root, 用免密 sudo 建好; _CONTAINERS_USERNS_CONFIGURED=1 由镜像 ENV
#      提供)。宿主侧还需的 /dev/fuse、seccomp 条件见 docs/deployment.md。
#   5. exec dsh-web —— dsh web 的启动/监督、会话 cookie 的就绪等待与 Caddy
#      反代全部由 dsh-web 托管(会话 cookie 自举由容器适配插件在 dsh 进程内
#      完成, 见 container/plugin/ 与 container/dsh-web.sh)。
# 附加参数会原样透传给 dsh web, 例如 --port 8080。
# 遥测默认关闭: dsh 的反馈 OTel 上报(默认 FEEDBACK_ONLY 时, 用户点反馈会把
# 完整会话上下文发往 harness-telemetry.deepseeksvc.com)在本镜像中默认
# DISABLED; 用户可用 DSH_TELEMETRY_MODE / DSH_TELEMETRY_OTLP_URL 显式开启
# 或改端点(见 docs/security.md)。注意这只覆盖 OTel 路径: 上游默认挂载的
# DeepSeek 会话日志贡献者(session-log-deepseek)不受该变量控制, 详见
# docs/security.md "Telemetry is off by default"。
set -euo pipefail

# 数值 USER 不自动设置 HOME; 从 passwd 还原, 供 npm/uv/cargo 等使用。
# 用 if ! 捕获 getent 失败, 再校验非空, 不退化到 /dsh 这类根路径。
if ! HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"; then
  echo "[entrypoint] cannot resolve HOME for uid $(id -u)" >&2
  exit 1
fi
if [ -z "$HOME" ]; then
  echo "[entrypoint] empty HOME for uid $(id -u)" >&2
  exit 1
fi
export HOME

# 分层: 工具链归镜像(系统层), 卷只放数据/缓存/自装工具:
# - dsh 数据不设置 DSH_HOME, 使用上游默认 ~/.dsh
# - dsh 的 cwd 固定为 $HOME; 不预创建固定工作区目录, dsh 会按需创建
# - rust 工具链树: /opt/rust/rustup(镜像所有但运行期可写 —— 构建时属主已设
#   为 dsh, 启动时兜底自愈; 升级随镜像)
# - cargo 可写区: ~/.cargo(registry/cache, cargo install 自装 bin 也在这)
# - uv 数据: ~/.local/share/uv、~/.cache/uv(uv 管理的 Python 也在这)
# - pnpm: PNPM_HOME=~/.local/share/pnpm 只当 store 与自装全局包目录
export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rust/rustup}"
# rustup 运行期需要写 RUSTUP_HOME(settings.toml/tmp/downloads/toolchains)。
# 镜像构建时属主已设为 dsh; 容器重建/快照把属主冲回 root 时这里兜底修复。
# 注意: 用户覆盖 RUSTUP_HOME 指向尚不存在的目录(见 docs/build.md 自定义
# 工具链逃生通道)时跳过 —— 该目录由 rustup 首次使用时自建。
if [ "$(id -u)" != 0 ] && [ -d "$RUSTUP_HOME" ] \
    && [ "$(stat -c %u "$RUSTUP_HOME" 2>/dev/null)" != "$(id -u)" ]; then
  echo "[entrypoint] fixing ownership of $RUSTUP_HOME for $(id -un)" >&2
  sudo chown -R "$(id -u):$(id -g)" "$RUSTUP_HOME"
fi
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
# 遥测默认关闭(镜像层默认, 用户可覆盖): 点反馈等显式交互也不会上报
# OTel; 显式设置 DSH_TELEMETRY_MODE=FEEDBACK_ONLY 或 DSH_TELEMETRY_OTLP_URL
# 可恢复上游默认行为。
export DSH_TELEMETRY_MODE="${DSH_TELEMETRY_MODE:-DISABLED}"
mkdir -p "$HOME/.cargo/bin" "$HOME/.local/bin" "$PNPM_HOME"
# PATH 镜像优先 (hermes-agent 模式): /usr/local/bin 里是镜像的真二进制
# (dsh/uv/pnpm/cargo), 必须压过用户层目录; 用户自装工具垫底。
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# 容器内 podman 运行期环境(尽力而为; 宿主侧要满足的条件见 docs/deployment.md
# "容器内 podman"): rootless podman 必须能写 XDG_RUNTIME_DIR(libpod 运行时
# 状态、pause 进程、API socket 都放这里), 缺失或不可写会直接启动失败。容器无
# login session, /run/user/$UID 默认不存在, 且 /run 属 root —— 用免密 sudo
# 建好并交给当前用户; sudo 不可用时退到 /tmp 下的自有目录(podman 对 tmpfs
# 无硬性要求, 0700 自有目录即可)。镜像 ENV 的 _CONTAINERS_USERNS_CONFIGURED=1
# 已让内层 podman 跳过创建用户命名空间(免 newuidmap 失败; 于是它只能在当前
# userns 里建命名空间 —— rootful 宿主因此需要 CAP_SYS_ADMIN, 见 docs/deployment.md),
# exec shell 的兜底导出在 /etc/bash.bashrc。
if [ "$(id -u)" = 0 ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
elif [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -w "${XDG_RUNTIME_DIR:-/nonexistent}" ]; then
  runtime_dir="/run/user/$(id -u)"
  if ! sudo -n mkdir -p "$runtime_dir" 2>/dev/null \
     || ! sudo -n chown "$(id -u):$(id -g)" "$runtime_dir" 2>/dev/null; then
    runtime_dir="/tmp/xdg-runtime-$(id -u)"
    mkdir -p "$runtime_dir" 2>/dev/null || true
  fi
  if [ -d "$runtime_dir" ]; then
    chmod 700 "$runtime_dir" 2>/dev/null || true
    export XDG_RUNTIME_DIR="$runtime_dir"
  else
    echo "[entrypoint] WARNING: cannot provision XDG_RUNTIME_DIR; rootless podman will not run" >&2
  fi
fi
cd "$HOME"

# 从附加参数中提取 --port <N> / --port=<N>, 作为 dsh web 的内部监听端口
# (对外端口固定 3081, 由 Caddy 反代, 不受影响)。
PORT=3080
prev=
for a in "$@"; do
  case "$a" in
    --port=*) PORT="${a#--port=}" ;;
  esac
  if [ "$prev" = "--port" ]; then PORT="$a"; fi
  prev="$a"
done
case "$PORT" in
  ''|*[!0-9]*)
    echo "[entrypoint] invalid --port value: '$PORT' (must be a number)" >&2
    exit 1
    ;;
esac
if [ "$PORT" = "0" ]; then
  echo "[entrypoint] --port 0 is not supported: the Caddy proxy needs a fixed internal port" >&2
  exit 1
fi
if [ "$PORT" = "3081" ]; then
  echo "[entrypoint] --port 3081 conflicts with the exposed Caddy proxy port; choose a different internal port" >&2
  exit 1
fi

# 内部端口经环境传给 dsh-web(它挂载容器适配插件启动 dsh web —— 插件完成
# 会话 cookie 自举 —— 并托管 Caddy 反代与整个服务栈)。
export DSH_WEB_PORT="$PORT"

exec dsh-web "$@"
