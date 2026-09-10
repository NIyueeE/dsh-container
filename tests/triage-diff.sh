#!/usr/bin/env bash
# 上游 diff 分诊(代码级判断): 决定 release-prep 的 agent 是否需要入场。
# 原则: agent 晚入场、早退出 —— 能用代码判定的, 绝不让 LLM 跑一遍。
#
# 判定逻辑(按优先级):
#   1. ancestor(新 tag 落后于已有发布, 误派发)  -> agent 不入场, 流水线应失败
#   2. fatal(安全围栏类契约漂移)                -> agent 不入场, 流水线应失败
#   3. 契约漂移(非 fatal)                       -> agent 入场(修复是语义工作)
#   4. 契约干净但 diff 命中适配面                -> agent 入场(简化审查)
#   5. 契约干净且 diff 未命中适配面              -> agent 不入场
#   6. 文件清单不完整(compare API 300 上限)      -> 无法证明未命中, 保守放行
#
# 适配面(上游路径) = 契约锚点(见 tests/contract.sh) ∪ Simplification triggers
# 的检测路径(见 docs/upstream-contract.md § Simplification triggers)。
# 两个清单需与上述文档同步维护。
#
# 用法:
#   tests/triage-diff.sh (--files <path>|--diff <json>) --verdict <clean|drift> \
#     [--missed 'check-id...'] [--status <compare-status>]
#     --files    换行分隔的变更文件清单(推荐: git diff --name-only 的完整
#                清单; compare API 有 300 文件上限, 会漏掉适配面)
#     --diff     GitHub compare payload(JSON, 兜底; 文件数>=300 视为不完整)
#     --verdict  contract.sh 结论(clean/drift)
#     --missed   契约 MISS 的 check-id 列表(空格分隔, 可空)
#     --status   compare 的 status 字段(behind = 误派发旧版本)
# 输出(逐行):
#   TRIAGE ancestor=yes|no
#   TRIAGE fatal=yes|no
#   TRIAGE surface_hits=<path,path,...|none|unknown(compare-truncated)>
#   TRIAGE agent_required=yes|no
# 退出码: 0 = 正常判定; 1 = 输入/基础设施错误
set -euo pipefail

FILES=""
DIFF=""
VERDICT=""
MISSED=""
STATUS=""

usage() {
  echo "usage: tests/triage-diff.sh (--files <path>|--diff <json>) --verdict <clean|drift> [--missed 'id...'] [--status <s>]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --files) [ $# -ge 2 ] || usage; FILES="$2"; shift 2 ;;
    --diff) [ $# -ge 2 ] || usage; DIFF="$2"; shift 2 ;;
    --verdict) [ $# -ge 2 ] || usage; VERDICT="$2"; shift 2 ;;
    --missed) [ $# -ge 2 ] || usage; MISSED="$2"; shift 2 ;;
    --status) [ $# -ge 2 ] || usage; STATUS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unexpected argument: $1" >&2; usage ;;
  esac
done

[ -n "$VERDICT" ] || usage
[ -n "$FILES" ] || [ -n "$DIFF" ] || usage

# 安全围栏类 check-id(见 tests/contract.sh): 漂移时 agent 不得绕行,
# 由流水线直接失败并留证 —— 这是安全边界, 不交给 LLM 判断。
FATAL_IDS="server.request_fence"

# 适配面: 上游路径前缀(正则)。命中任一即需要 agent 做语义审查。
# - packages/client/connection/      isLoopback 补丁锚点 + /api 围栏 + authenticatedUrl
# - packages/api/settings-controller/  settings describe/documentPath 契约
# - packages/client/ui-settings-general/  SettingsDocumentAction 渲染门
# - apps/cli/src/                    CLI 契约(--port/--patch/--no-open 与会话入口)
# - packages/bundle/base/            遥测默认值等 bundle 层契约
SURFACE_PAT='^(packages/client/connection/|packages/api/settings-controller/|packages/client/ui-settings-general/|apps/cli/src/|packages/bundle/base/)'

ancestor=no
[ "$STATUS" = "behind" ] && ancestor=yes

fatal=no
for id in $MISSED; do
  case " $FATAL_IDS " in
    *" $id "*) fatal=yes ;;
  esac
done

hits="none"
if [ -n "$FILES" ]; then
  [ -f "$FILES" ] || { echo "error: --files $FILES does not exist" >&2; exit 1; }
  hits="$(grep -E "$SURFACE_PAT" "$FILES" | sort -u | paste -sd, - || true)"
  [ -n "$hits" ] || hits="none"
elif [ -f "$DIFF" ]; then
  count="$(jq '[.files[]?] | length' "$DIFF" 2>/dev/null || echo 0)"
  if [ "$count" -ge 300 ]; then
    # compare API 上限 300 文件: 清单不完整, 无法证明未命中适配面
    hits="unknown(compare-truncated)"
  else
    hits="$(jq -r '.files[].filename // empty' "$DIFF" 2>/dev/null \
      | grep -E "$SURFACE_PAT" | sort -u | paste -sd, - || true)"
    [ -n "$hits" ] || hits="none"
  fi
else
  echo "error: --diff $DIFF does not exist" >&2
  exit 1
fi

agent=no
if [ "$ancestor" = yes ] || [ "$fatal" = yes ]; then
  agent=no
elif [ "$VERDICT" = drift ] || [ "$hits" != "none" ]; then
  agent=yes
fi

echo "TRIAGE ancestor=$ancestor"
echo "TRIAGE fatal=$fatal"
echo "TRIAGE surface_hits=$hits"
echo "TRIAGE agent_required=$agent"
