#!/usr/bin/env bash
# claude-executor/bin/queue-run.sh
#
# 未消化 issue を優先度順に並べて 1 件ずつ issue-consumer.sh に渡す
# orchestrator。並列はしない (= 同時 1 体)、cooldown と in-flight を尊重。
#
# Usage:
#   claude-executor/bin/queue-run.sh                # 1 件処理して exit (one-shot)
#   claude-executor/bin/queue-run.sh --max 5        # 最大 5 件処理 (順次)
#   claude-executor/bin/queue-run.sh --watch        # 終わるまで延々処理 (= 全部 OK か全部 cooldown まで)
#   claude-executor/bin/queue-run.sh --milestone "MVP 本番リリース"  # 特定 milestone のみ
#   claude-executor/bin/queue-run.sh --priority high                  # priority 絞り込み
#   claude-executor/bin/queue-run.sh --issue 217                       # 特定 issue だけ

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${EXECUTOR_PROJECT_NAME:-manademia}"
MAX="${ISSUE_QUEUE_MAX:-1}"
MILESTONE_FILTER=""
PRIORITY_FILTER=""
SPECIFIC_ISSUE=""
WATCH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max) shift; MAX="$1"; shift ;;
    --milestone) shift; MILESTONE_FILTER="$1"; shift ;;
    --priority) shift; PRIORITY_FILTER="$1"; shift ;;
    --issue) shift; SPECIFIC_ISSUE="$1"; shift ;;
    --watch) WATCH=1; MAX=999; shift ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date +%H:%M:%S)] $*"; }

# === Queue 構築 ===
build_queue() {
  if [[ -n "$SPECIFIC_ISSUE" ]]; then
    echo "$SPECIFIC_ISSUE"
    return
  fi
  # gh issue list で取得、priority 順 + milestone 順
  local args=()
  if [[ -n "$MILESTONE_FILTER" ]]; then
    args+=(--milestone "$MILESTONE_FILTER")
  fi
  if [[ -n "$PRIORITY_FILTER" ]]; then
    args+=(--label "priority/$PRIORITY_FILTER")
  fi

  # env でカスタマイズ可:
  #   EXECUTOR_SKIP_LABELS / EXECUTOR_SKIP_MILESTONES (= consumer.sh と統一)
  #   EXECUTOR_PRIORITY_ORDER: "priority/critical:0,priority/high:1,priority/medium:2,priority/low:3"
  #   EXECUTOR_MILESTONE_ORDER: "milestone-title-A:0,milestone-title-B:1,..."
  gh issue list --state open --limit 250 "${args[@]}" --json number,labels,milestone 2>/dev/null \
    | EXECUTOR_SKIP_LABELS="${EXECUTOR_SKIP_LABELS:-area/legal,priority/low,consumer-skip}" \
      EXECUTOR_SKIP_MILESTONES="${EXECUTOR_SKIP_MILESTONES:-Long-term (Phase 11+)}" \
      EXECUTOR_PRIORITY_ORDER="${EXECUTOR_PRIORITY_ORDER:-priority/critical:0,priority/high:1,priority/medium:2,priority/low:3}" \
      EXECUTOR_MILESTONE_ORDER="${EXECUTOR_MILESTONE_ORDER:-MVP 本番リリース:0,本番後 1 ヶ月 (Quick wins):1,本番後 3 ヶ月 (Phase 1D/1E 完了):2,本番後 6 ヶ月 (Phase 4-7):3,本番後 1 年 (Phase 9-10):4,Long-term (Phase 11+):99}" \
      python3 -c '
import json, os, sys

def parse_ordered(env_value):
    out = {}
    for entry in env_value.split(","):
        entry = entry.strip()
        if not entry: continue
        if ":" not in entry: continue
        k, v = entry.rsplit(":", 1)
        try: out[k.strip()] = int(v.strip())
        except ValueError: pass
    return out

PRIORITY_ORDER = parse_ordered(os.environ.get("EXECUTOR_PRIORITY_ORDER", ""))
MILESTONE_ORDER = parse_ordered(os.environ.get("EXECUTOR_MILESTONE_ORDER", ""))
SKIP_LABELS = [s.strip() for s in os.environ.get("EXECUTOR_SKIP_LABELS", "").split(",") if s.strip()]
SKIP_MILESTONES = [s.strip() for s in os.environ.get("EXECUTOR_SKIP_MILESTONES", "").split(",") if s.strip()]

def skip_reason(it):
    names = [l["name"] for l in it.get("labels", [])]
    for sl in SKIP_LABELS:
        if sl in names: return sl
    m = it.get("milestone") or {}
    if m.get("title") in SKIP_MILESTONES: return "milestone:" + m.get("title")
    return None
def sort_key(it):
    names = [l["name"] for l in it.get("labels", [])]
    pri = min([PRIORITY_ORDER.get(n, 99) for n in names if n.startswith("priority/")] or [99])
    m = it.get("milestone") or {}
    mi = MILESTONE_ORDER.get(m.get("title"), 99)
    return (pri, mi, it["number"])

issues = json.load(sys.stdin)
eligible = [i for i in issues if skip_reason(i) is None]
eligible.sort(key=sort_key)
for it in eligible:
    print(it["number"])
'
}

QUEUE="$(build_queue)"
if [[ -z "$QUEUE" ]]; then
  log "queue is empty"
  exit 0
fi

TOTAL=$(echo "$QUEUE" | wc -l)
log "queue size: $TOTAL issue(s), max $MAX to process"

PROCESSED=0
SKIPPED=0
FAILED=0
SUCCEEDED=0

for ISSUE in $QUEUE; do
  if [[ "$PROCESSED" -ge "$MAX" ]]; then
    log "max reached ($MAX), stopping"
    break
  fi
  log "--- processing issue #$ISSUE ($((PROCESSED + 1))/$MAX) ---"
  bash "$REPO/claude-executor/bin/consumer.sh" "$ISSUE"
  RC=$?
  STATUS="$(cat "/tmp/${PROJECT}-issue-consumer-${ISSUE}.status" 2>/dev/null || echo 'no-status')"
  case "$STATUS" in
    OK:PR*)    SUCCEEDED=$((SUCCEEDED + 1)) ;;
    OK:skipped*|OK:in-flight*|OK:not-open*|OK:no-fail*)
               SKIPPED=$((SKIPPED + 1)) ;;
    *)         FAILED=$((FAILED + 1)) ;;
  esac
  PROCESSED=$((PROCESSED + 1))
  log "issue #$ISSUE: $STATUS (rc=$RC)"
done

log "============================="
log "processed: $PROCESSED"
log "  succeeded: $SUCCEEDED"
log "  skipped:   $SKIPPED"
log "  failed:    $FAILED"
log "============================="
