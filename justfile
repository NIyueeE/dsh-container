# dsh 容器镜像常用命令(需 podman 或 docker)

container := if command -v podman >/dev/null 2>&1 { "podman" } else { "docker" }

# 本地构建镜像(不推送)。--format docker 保留 HEALTHCHECK
# (podman 默认 OCI 格式会丢弃 HEALTHCHECK, 与 GHCR 发布镜像保持一致)。
build:
    {{container}} build --format docker -t ghcr.io/niyueee/dsh-container:local .

# 前台调试运行(桥接 + 端口映射, 关闭自动更新, 数据放临时目录)
debug:
    {{container}} run --rm -p 3080:3080 \
        -e DSH_HOME=/tmp/dsh-debug-home \
        -e DSH_AUTO_UPDATE=0 \
        ghcr.io/niyueee/dsh-container:local

# 仅执行 dsh 自动更新后退出(可用 cron/timer 定时调用)
update-only:
    {{container}} run --rm -e DSH_UPDATE_ONLY=1 ghcr.io/niyueee/dsh-container:latest
