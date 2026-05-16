#!/usr/bin/env bash
# claude-executor/bin/dashboard.sh
#
# issue-consumer 稼働状況のスナップショット表示。
# stats.jsonl + 現在稼働中の lockfile + 直近 status file から集約。
#
# Usage:
#   claude-executor/bin/dashboard.sh           # 1 回表示
#   claude-executor/bin/dashboard.sh --watch   # 30s ごとに更新

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${EXECUTOR_PROJECT_NAME:-manademia}"
STATS_FILE="$REPO/logs/consumer-stats.jsonl"
GLOBAL_LOCK="/tmp/${PROJECT}-issue-consumer.lock"
QUEUE_LOG="$REPO/logs/issue-queue-watch.log"

WATCH=0
[[ "${1:-}" == "--watch" ]] && WATCH=1

show() {
  clear
  echo "================================================================"
  echo " issue-consumer dashboard  ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
  echo "================================================================"
  echo ""

  # === 稼働状態 ===
  if [[ -f "$GLOBAL_LOCK" ]]; then
    LOCK_PID="$(cat "$GLOBAL_LOCK" 2>/dev/null || echo '')"
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
      ELAPSED="$(ps -o etime= -p "$LOCK_PID" 2>/dev/null | tr -d ' ')"
      CURRENT_ISSUE="$(find /tmp -maxdepth 1 -name 'manademia-issue-consumer-*.status' -newer "$GLOBAL_LOCK" -printf '%f\n' 2>/dev/null | sed 's/.*-\([0-9]*\)\.status/\1/' | head -1)"
      [[ -z "$CURRENT_ISSUE" ]] && CURRENT_ISSUE="?"
      printf '  状態: 🟢 ACTIVE (PID=%s, 経過=%s, 推定 issue=#%s)\n' "$LOCK_PID" "$ELAPSED" "$CURRENT_ISSUE"
    else
      echo "  状態: 💤 idle (stale lock 検出: $LOCK_PID)"
    fi
  else
    echo "  状態: 💤 idle (no lock)"
  fi

  # === Queue runner (= orchestrator) ===
  QUEUE_PIDS="$(pgrep -f 'issue-queue-run\.sh' 2>/dev/null | head -1)"
  if [[ -n "$QUEUE_PIDS" ]]; then
    Q_ELAPSED="$(ps -o etime= -p "$QUEUE_PIDS" 2>/dev/null | tr -d ' ')"
    printf '  Queue orchestrator: 🟢 ACTIVE (PID=%s, 経過=%s)\n' "$QUEUE_PIDS" "$Q_ELAPSED"
  else
    echo "  Queue orchestrator: 💤 not running"
  fi
  echo ""

  # === Stats 集計 ===
  if [[ -f "$STATS_FILE" ]]; then
    TOTAL="$(wc -l < "$STATS_FILE")"
    OK="$(grep -c '"status":"OK"' "$STATS_FILE" 2>/dev/null || echo 0)"
    SKIP="$(grep -c '"status":"OK:skip' "$STATS_FILE" 2>/dev/null || echo 0)"
    FAIL="$(grep -c '"status":"FAILED' "$STATS_FILE" 2>/dev/null || echo 0)"
    GATE_FAIL="$(grep -c 'quality-gate' "$STATS_FILE" 2>/dev/null || echo 0)"
    echo "  累積 stats (logs/consumer-stats.jsonl):"
    printf '    total: %3d run(s)\n' "$TOTAL"
    printf '    ✅ OK:           %3d\n' "$OK"
    printf '    ⏭️  SKIP:         %3d\n' "$SKIP"
    printf '    ❌ FAIL:         %3d\n' "$FAIL"
    printf '    ⚠️  quality-gate: %3d\n' "$GATE_FAIL"
    echo ""
    echo "  直近 5 件:"
    tail -5 "$STATS_FILE" 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        d = json.loads(line)
        print(f"    #{d[\"issue\"]:>3} {d.get(\"kind\",\"?\"):<13} {d.get(\"model\",\"?\"):<25} {d.get(\"status\",\"?\")} ({d.get(\"elapsed_sec\",0)}s)")
    except: pass
'
  else
    echo "  累積 stats: なし (logs/consumer-stats.jsonl)"
  fi
  echo ""

  # === Open PR + merged 本 session ===
  OPEN_PR="$(gh pr list --state open --json number 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' || echo '?')"
  MERGED_SESS="$(gh pr list --state merged --limit 100 --json number 2>/dev/null \
    | python3 -c 'import json,sys;print(len([r for r in json.load(sys.stdin) if r["number"]>=417]))' || echo '?')"
  echo "  📋 PR status: open=$OPEN_PR, merged_session=$MERGED_SESS"
  echo ""

  # === Queue 残量 (eligible) ===
  if command -v gh >/dev/null 2>&1; then
    ELIGIBLE="$(gh issue list --state open --limit 250 --json labels,milestone 2>/dev/null \
      | python3 -c '
import json, sys
data = json.load(sys.stdin)
def skippable(it):
    names = [l["name"] for l in it.get("labels", [])]
    if "area/legal" in names: return True
    if "priority/low" in names: return True
    if "consumer-skip" in names: return True
    m = it.get("milestone") or {}
    if m.get("title") == "Long-term (Phase 11+)": return True
    return False
eligible = [i for i in data if not skippable(i)]
print(len(eligible))
' || echo '?')"
    echo "  📥 残 eligible queue: $ELIGIBLE 件"
  fi
  echo ""

  # === 最新 queue log ===
  if [[ -f "$QUEUE_LOG" ]]; then
    echo "  📜 queue runner 直近 3 行:"
    tail -3 "$QUEUE_LOG" | sed 's/^/    /'
  fi
}

if [[ "$WATCH" -eq 1 ]]; then
  while true; do
    show
    sleep 30
  done
else
  show
fi
