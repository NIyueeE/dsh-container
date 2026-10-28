#!/usr/bin/env bash
# 静态门禁(单一来源): ci.yml 的 light job(以及 publish.yml 复用的同一条)、
# 本地 `just lint` 都跑这一套。轻门只做静态检查, 永不构建镜像。
#
# 用法:
#   tests/validate-static.sh                 # 完整(CI; 需要 docker + sudo/systemd)
#   tests/validate-static.sh --no-runtime    # 跳过 compose/quadlet(本地 just lint)
#
# 重门(构建 + smoke)不在本脚本里: 它是 smoke.yml 调用的 tests/smoke.sh,
# 因为静态检查不能代替行为验证。
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
# 排除本脚本和 workflow 自身: 它们包含下面这些模式字符串。
if grep -RIn --exclude-dir=.git --exclude='validate-static.sh' --exclude='*.yml' \
     -E 'DSH_AUTO_UPDATE|dsh-update|update-dsh|DSH_VERSION|@deepseek-ai/dsh@' .; then
  echo "found references to removed dsh auto-update / npm install" >&2
  exit 1
fi
if grep -rnE 'DSH_AUTO_UPDATE[ =:]|dsh-update\.sh|update-dsh[ :]|DSH_VERSION[ =:]' .github/workflows/; then
  echo "workflow still references removed dsh auto-update / npm install" >&2
  exit 1
fi

echo "== smoke.sh fail-closed audit"
# smoke 里允许 `|| true` 只用于 trap/日志/探针, 且必须标注原因(见文件头的约定);
# 未标注的宽容写法会让"失败被吞掉"悄悄回归。
if grep -nE '\|\| true' tests/smoke.sh | grep -v '# ok:'; then
  echo "tests/smoke.sh: every '|| true' needs a '# ok: <reason>' annotation" >&2
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
