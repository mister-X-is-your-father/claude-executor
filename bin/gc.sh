#!/usr/bin/env bash
# claude-executor/bin/gc.sh
#
# 古い issue-consumer worktree (`/tmp/manademia-issue-N/`) と issue branch
# (`issue/N`) を garbage collect する。
#
# 動作:
#   1. /tmp/manademia-issue-*/ を列挙
#   2. 各 worktree について:
#      - PR が merged or closed なら worktree 削除 + branch 削除
#      - PR が open + 24h 以上経過 + lockfile 不在 (= consumer 終了済) なら残す
#      - PR が無い (= consumer 失敗) + 24h 以上経過なら強制削除 (= rescue 不能)
#   3. /tmp/manademia-issue-consumer-*.status の古い file も clean (= 7 日経過で削除)
#
# Usage:
#   claude-executor/bin/gc.sh                # 1 回実行
#   claude-executor/bin/gc.sh --dry-run      # 削除候補だけ表示
#
# Cron 推奨: 1 時間ごと
#   crontab: 0 * * * * bash /home/neo/manademia/claude-executor/bin/gc.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { echo "[$(date +%H:%M:%S)] $*"; }

# === 1. worktree GC ===
removed=0
kept=0
for wt in /tmp/manademia-issue-*/; do
  [[ -d "$wt" ]] || continue
  issue_num="$(basename "$wt" | sed 's/manademia-issue-//')"
  [[ ! "$issue_num" =~ ^[0-9]+$ ]] && continue

  # branch 名
  branch="issue/$issue_num"

  # PR 検索
  pr_state="$(gh pr list --state all --search "head:$branch in:branch" \
    --json number,state,createdAt --limit 5 2>/dev/null \
    | python3 -c '
import json, sys
rs = json.load(sys.stdin)
if not rs:
    print("none||")
else:
    r = rs[0]
    print(r["state"] + "|" + str(r["number"]) + "|" + r["createdAt"])
')"
  IFS='|' read -r STATE PR_NUM CREATED <<< "$pr_state"

  # lockfile check (= 現在 consumer 走行中なら触らない)
  LOCK="/tmp/manademia-issue-consumer.lock"
  if [[ -f "$LOCK" ]]; then
    LOCK_PID="$(cat "$LOCK" 2>/dev/null || echo '')"
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
      # current consumer の worktree か?
      if ls -la /proc/$LOCK_PID/cwd 2>/dev/null | grep -q "manademia-issue-$issue_num"; then
        log "SKIP: #$issue_num (current consumer working)"
        kept=$((kept + 1))
        continue
      fi
    fi
  fi

  # 経過時間 (= worktree 作成からの経過)
  wt_age=$(( $(date +%s) - $(stat -c %Y "$wt") ))

  case "$STATE" in
    MERGED|CLOSED)
      action="REMOVE (PR #$PR_NUM $STATE)"
      ;;
    OPEN)
      if [[ "$wt_age" -gt 86400 ]]; then
        action="SKIP (PR #$PR_NUM OPEN, $wt_age s old、watcher 待ち)"
        kept=$((kept + 1))
        continue
      else
        action="SKIP (PR #$PR_NUM OPEN, recent)"
        kept=$((kept + 1))
        continue
      fi
      ;;
    none|"")
      if [[ "$wt_age" -gt 86400 ]]; then
        action="REMOVE (no PR、24h+ orphan)"
      else
        action="SKIP (no PR、recent、retry 余地)"
        kept=$((kept + 1))
        continue
      fi
      ;;
    *)
      action="SKIP (state=$STATE unknown)"
      kept=$((kept + 1))
      continue
      ;;
  esac

  log "$action: $wt"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    git -C "$REPO" worktree remove "$wt" --force 2>/dev/null || rm -rf "$wt"
    git -C "$REPO" branch -D "$branch" 2>/dev/null || true
    removed=$((removed + 1))
  fi
done

# === 2. status file GC (7 日以上前) ===
status_removed=0
for sf in /tmp/manademia-issue-consumer-*.status; do
  [[ -f "$sf" ]] || continue
  age=$(( $(date +%s) - $(stat -c %Y "$sf") ))
  if [[ "$age" -gt 604800 ]]; then  # 7 days
    log "REMOVE old status: $sf (age=${age}s)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      rm -f "$sf"
      status_removed=$((status_removed + 1))
    fi
  fi
done

# === 3. log file GC (= 30 日以上前) は logrotate に任せる、本 GC は touch しない ===

log "GC summary: worktrees removed=$removed kept=$kept, status files removed=$status_removed"
[[ "$DRY_RUN" -eq 1 ]] && log "(dry-run、実削除はしてない)"
