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

# 在不重启容器的情况下重启容器内的 dsh web(dsh-web 守护会自动重新拉起)
restart-dsh:
    {{container}} exec dsh dsh-restart

# 对已构建镜像跑冒烟测试(先 just build; DOCKER 已按 podman/docker 自动选择)
test image="ghcr.io/niyueee/dsh-container:local":
    DOCKER={{container}} tests/smoke.sh {{image}}

# 对上游 tag 跑契约静态检查(浅克隆上游, 数秒判定兼容漂移;
# 本地已有 checkout 时直接调 tests/contract.sh --tag X --dir PATH 更快)
contract tag:
    tests/contract.sh --tag {{tag}}
