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
#   4. 幂等清理旧版(v0.2.x)镜像遗留在卷中的 npm 版 dsh 后, exec dsh-web ——
#      dsh web、会话 cookie 自举与 Caddy 反代的启动/监督全部由 dsh-web
#      托管, 详见 container/dsh-web.sh。
# 附加参数会原样透传给 dsh web, 例如 --port 8080。
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

# 分层: 工具链归镜像(系统层, 只读), 卷只放数据/缓存/自装工具:
# - dsh 数据不设置 DSH_HOME, 使用上游默认 ~/.dsh
# - dsh 的 cwd 固定为 $HOME; 不预创建固定工作区目录, dsh 会按需创建
# - rust 工具链树: /opt/rust/rustup(镜像所有, 只读; 升级随镜像)
# - cargo 可写区: ~/.cargo(registry/cache, cargo install 自装 bin 也在这)
# - uv 数据: ~/.local/share/uv、~/.cache/uv(uv 管理的 Python 也在这)
# - pnpm: PNPM_HOME=~/.local/share/pnpm 只当 store 与自装全局包目录
export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rust/rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
mkdir -p "$HOME/.cargo/bin" "$HOME/.local/bin" "$PNPM_HOME"
# PATH 镜像优先 (hermes-agent 模式): /usr/local/bin 里是镜像的真二进制
# (dsh/uv/pnpm/cargo), 必须压过用户层目录; 用户自装工具垫底。
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME"

# 迁移: 旧镜像 (v0.2.x) 曾把 dsh 作为 npm 全局包装进持久化用户层
# (~/.local), 旧数据卷会遮蔽镜像内新版本; 启动时幂等清除旧副本
# (失败仅告警, 不阻塞启动), 详见 container/dsh-migrate-legacy.sh。
if ! dsh-migrate-legacy; then
  echo "[entrypoint] legacy dsh migration failed; continuing" >&2
fi

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

# 内部端口经环境传给 dsh-web(它负责会话自举、Caddy 反代与整个服务栈)。
export DSH_WEB_PORT="$PORT"

exec dsh-web "$@"
