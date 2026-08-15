# dsh 容器镜像常用命令(需 podman 或 docker)

container := `command -v podman >/dev/null 2>&1 && echo podman || echo docker`
build_format := if container == "podman" { "--format docker" } else { "" }

# 本地构建镜像(不推送)。podman 必须用 --format docker 保留 HEALTHCHECK
# (podman 默认 OCI 格式会丢弃 HEALTHCHECK); docker 不支持该 flag, 因此条件传入。
build:
    {{container}} build {{build_format}} -t ghcr.io/niyueee/dsh-container:local .

# 前台调试运行(桥接 + 端口映射; --rm 退出后用户层改动随容器丢弃)
debug:
    {{container}} run --rm -p 3081:3081 \
        ghcr.io/niyueee/dsh-container:local

# 更新正在运行的 dsh 容器内的全局 npm 包(运行中的 dsh web 需重启后生效)
update-dsh:
    {{container}} exec dsh dsh-update
