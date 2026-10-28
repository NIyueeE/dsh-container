#!/usr/bin/env bash
# 静态门禁(单一来源): image.yml 的 validate job、release-prep 的 verify job
# 和本地 `just lint` 都跑这一套。verify 在推 tag 之前跑它, 保证 tag 不会在
# image.yml 的 validate 阶段才失败。
#
# 用法:
#   tests/validate-static.sh                 # 完整(CI; 需要 docker + sudo/systemd)
#   tests/validate-static.sh --no-runtime    # 跳过 compose/quadlet(本地 just lint)
#
# 不在这里跑 tests/contract.sh: 它需要上游 tag, 由 image.yml(tag build)和
# release-prep verify 单独调用。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

run_runtime=1
if [ "${1:-}" = "--no-runtime" ]; then
  run_runtime=0
  shift
fi
if [ "$#" -ne 0 ]; then
  echo "usage: tests/validate-static.sh [--no-runtime]" >&2
  exit 64
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "validate-static: shellcheck is required (Debian/Ubuntu: apt install shellcheck)" >&2
  exit 1
fi

echo "== shell syntax and lint"
bash -n container/*.sh tests/*.sh
shellcheck --severity=warning container/*.sh tests/*.sh

echo "== container-adapt plugin contract and JS syntax"
node tests/plugin-unit.mjs
node --check container/plugin/index.js
node --check container/plugin/lib/client.js
node --check container/plugin/scripts/extract-inline-assets.js
node --check container/plugin/scripts/minify-client.mjs
node --check container/plugin/scripts/refresh-build-record.mjs
node --check tests/newest-tag.mjs tests/semver.mjs tests/compare-tags.mjs
# semver 稳定版必须高于同核心预发布版; 预发布版在没有稳定版时才是最新。
[ "$(NEW_TAG=dsh-v0.2.1 EXISTING=$'dsh-v0.2.1\ndsh-v0.2.1-rc.2' node tests/newest-tag.mjs)" = "true" ] \
  || { echo "newest-tag: stable tag was not treated as newest" >&2; exit 1; }
[ "$(NEW_TAG=dsh-v0.2.1-rc.2 EXISTING=$'dsh-v0.2.1\ndsh-v0.2.1-rc.2' node tests/newest-tag.mjs)" = "false" ] \
  || { echo "newest-tag: prerelease tag outranked its stable tag" >&2; exit 1; }
[ "$(NEW_TAG=dsh-v0.2.1-rc.2 EXISTING=$'dsh-v0.2.0\ndsh-v0.2.1-rc.2' node tests/newest-tag.mjs)" = "true" ] \
  || { echo "newest-tag: standalone prerelease was not newest" >&2; exit 1; }
# STRICT: 已存在的同名 tag 不算"更新"(发布守卫用它拒绝重发)。
[ "$(STRICT=1 NEW_TAG=dsh-v0.2.1 EXISTING=dsh-v0.2.1 node tests/newest-tag.mjs)" = "false" ] \
  || { echo "newest-tag: STRICT accepted an existing tag" >&2; exit 1; }
# compare-tags: 上游更新的预发布 tag 必须被识别。
[ "$(UPSTREAM_TAGS=$'dsh-v0.2.2-alpha.1\ndsh-v0.2.1' SELF_TAGS=dsh-v0.2.1-rc.3 node tests/compare-tags.mjs)" = '{"upstream":"dsh-v0.2.2-alpha.1","self":"dsh-v0.2.1-rc.3","upNewer":true}' ] \
  || { echo "compare-tags: newer upstream tag not detected" >&2; exit 1; }

echo "== documentation"
python3 tests/validate-docs.py links
python3 tests/validate-docs.py parity

echo "== removed auto-update remnants"
# 排除本脚本和 image.yml 自身: 它们包含下面这些模式字符串。
if grep -RIn --exclude-dir=.git --exclude='image.yml' --exclude='validate-static.sh' \
     -E 'DSH_AUTO_UPDATE|dsh-update|update-dsh|DSH_VERSION|@deepseek-ai/dsh@' .; then
  echo "found references to removed dsh auto-update / npm install" >&2
  exit 1
fi
if grep -nE 'DSH_AUTO_UPDATE[ =:]|dsh-update\.sh|update-dsh[ :]|DSH_VERSION[ =:]' .github/workflows/image.yml; then
  echo "workflow still references removed dsh auto-update / npm install" >&2
  exit 1
fi

if [ "$run_runtime" = 1 ]; then
  echo "== compose example"
  docker compose -f examples/compose.yaml config --quiet

  echo "== quadlet example"
  sudo mkdir -p /etc/containers/systemd
  sudo cp examples/dsh.container /etc/containers/systemd/
  sudo systemctl daemon-reload
  systemctl cat dsh.service >/dev/null
else
  echo "== compose/quadlet checks skipped (--no-runtime)"
fi

echo "validate-static: PASS"
