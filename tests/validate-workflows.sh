#!/usr/bin/env bash
# GitHub Actions workflow 静态检查: actionlint(schema、表达式、run 脚本的 shellcheck)
# + zizmor(权限/模板注入/未 pin 的 action/危险 trigger 等安全审计)。
# 两个工具都用固定 digest 的容器, 宿主只要 docker/podman 就能跑, 与 ci.yml 的
# light job / publish.yml 复用的同一条轻门 / 本地 `just lint-workflows` 共用同一份
# 判据(版本也不会随 runner 漂移)。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DOCKER="${DOCKER:-docker}"

command -v "$DOCKER" >/dev/null 2>&1 \
  || { echo "validate-workflows: $DOCKER is required (docker or podman)" >&2; exit 1; }

# 1.7.7 的多架构 index digest; 升级时同时改版本号和 digest。
ACTIONLINT_IMAGE="docker.io/rhysd/actionlint:1.7.7@sha256:887a259a5a534f3c4f36cb02dca341673c6089431057242cdc931e9f133147e9"
ZIZMOR_IMAGE="ghcr.io/zizmorcore/zizmor:1.31.1@sha256:cfc533b8fa781c51c6fb4085057945bc3eebb6b6e8a25ab7daa85c885f071269"

echo "== GitHub Actions workflow lint (actionlint 1.7.7)"
"$DOCKER" run --rm -v "$ROOT:/repo" -w /repo "$ACTIONLINT_IMAGE" .github/workflows/*.yml

echo "== GitHub Actions workflow security audit (zizmor 1.31.1)"
"$DOCKER" run --rm -v "$ROOT:/repo" -w /repo "$ZIZMOR_IMAGE" .github/workflows

echo "validate-workflows: PASS"
