# dsh 容器镜像常用命令(需 podman 或 docker)

container := `command -v podman >/dev/null 2>&1 && echo podman || echo docker`
build_format := if container == "podman" { "--format docker" } else { "" }

# 本地构建镜像(不推送)。podman 必须用 --format docker 保留 HEALTHCHECK
# (podman 默认 OCI 格式会丢弃 HEALTHCHECK); docker 不支持该 flag, 因此条件传入。
build:
    {{container}} build {{build_format}} -t ghcr.io/niyueee/dsh-container:local .

# 前台调试运行(回环端口映射, 与 examples 一致 —— 局域网暴露是显式
# 的 -p 3081:3081 改绑动作; --rm 退出后用户层改动随容器丢弃)
debug:
    {{container}} run --rm -p 127.0.0.1:3081:3081 \
        ghcr.io/niyueee/dsh-container:local

# 在不重启容器的情况下重启容器内的 dsh web(dsh-web 守护会自动重新拉起)
restart-dsh:
    {{container}} exec dsh dsh-restart

# 对已构建镜像跑冒烟测试(先 just build)。tag 是构建时传入的 DSH_TAG
# (just build 默认 latest), platform 是镜像平台:
#   just test ghcr.io/niyueee/dsh-container:local latest linux/amd64
test image="ghcr.io/niyueee/dsh-container:local" tag="latest" platform="linux/amd64":
    DOCKER={{container}} tests/smoke.sh {{image}} --expect-dsh-tag {{tag}} --expect-platform {{platform}}

# 本地静态门禁: 与 CI 的 validate job 共用 tests/validate-static.sh 的
# --no-runtime 模式(shell syntax/lint、插件契约、文档、移除项残留检查;
# 跳过需要 docker/systemd 的 compose/quadlet)。shellcheck 缺失时明确失败。
lint:
    tests/validate-static.sh --no-runtime

# workflow 静态检查(actionlint, 固定 digest 容器; 需要 docker 或 podman)
lint-workflows:
    DOCKER={{container}} tests/validate-workflows.sh
