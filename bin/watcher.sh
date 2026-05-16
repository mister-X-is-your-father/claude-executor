#!/usr/bin/env bash
# claude-executor/bin/watcher.sh
#
# CI green かつ mergeable な PR を自動 merge する poller。
# GitHub free private repo の paid auto-merge 機能の代替。
#
# Usage:
#   claude-executor/bin/watcher.sh                 # open 全 PR を 1 回チェック (one-shot)
#   claude-executor/bin/watcher.sh 13              # PR #13 を 1 回チェック
#   claude-executor/bin/watcher.sh --watch         # 60s 毎に全 PR を周回 (Ctrl+C で停止)
#   claude-executor/bin/watcher.sh --watch 13      # 60s 毎に PR #13 のみ周回
#
# 動作:
#   1. open かつ non-draft な PR を gh CLI で取得
#   2. 各 PR について以下を全て満たすか check:
#      - status checks: 全 success (or skipped)
#      - mergeable_state: clean / has_hooks
#      - mergeable: true
#      - 最低 1 commit
#   3. 全部 OK なら gh pr merge --merge --delete-branch を実行
#   4. fail / blocked / draft / conflict は skip + 理由 log 出力
#
# 安全規則:
#   - main / master / production ブランチへの直接実行はしない (pull request 経由のみ)
#   - --force / --admin オプションは使わない (CI fail を skip しない)
#   - merge strategy は "merge" 固定 (rebase / squash は user 設定でやり直し)
#
# Lockfile (--watch 時):
#   /tmp/merge-when-green.lock (PID 記録、stale 検出 + 削除)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCKFILE="/tmp/merge-when-green.lock"
WATCH_INTERVAL_SEC=60

# args
WATCH_MODE=0
PR_FILTER=""
for arg in "$@"; do
  case "$arg" in
    --watch) WATCH_MODE=1 ;;
    [0-9]*) PR_FILTER="$arg" ;;
    *)
      echo "Usage: $0 [--watch] [<PR_NUMBER>]" >&2
      exit 2 ;;
  esac
done

acquire_lock() {
  if [[ -f "$LOCKFILE" ]]; then
    local OLD_PID
    OLD_PID="$(cat "$LOCKFILE" 2>/dev/null || echo '')"
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "ERROR: another merge-when-green is running (PID=$OLD_PID)" >&2
      echo "  if stale: rm $LOCKFILE" >&2
      exit 1
    fi
    rm -f "$LOCKFILE"
  fi
  echo "$$" > "$LOCKFILE"
}

release_lock() {
  if [[ -f "$LOCKFILE" ]]; then
    local LOCK_PID
    LOCK_PID="$(cat "$LOCKFILE" 2>/dev/null || echo '')"
    if [[ "$LOCK_PID" == "$$" ]]; then
      rm -f "$LOCKFILE"
    fi
  fi
}

# 1 PR を check + (条件満たせば) merge
# returns 0 if merged, 1 if skipped, 2 if errored
check_and_merge() {
  local PR="$1"
  local INFO
  INFO="$(gh pr view "$PR" --json number,title,state,isDraft,mergeable,mergeStateStatus,statusCheckRollup,baseRefName,headRefName 2>/dev/null || echo '')"
  if [[ -z "$INFO" ]]; then
    echo "  PR #$PR: cannot fetch (deleted? or no permission)"
    return 2
  fi

  local STATE IS_DRAFT MERGEABLE MERGE_STATE TITLE BASE
  STATE="$(echo "$INFO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("state",""))')"
  IS_DRAFT="$(echo "$INFO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("isDraft",False))')"
  MERGEABLE="$(echo "$INFO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("mergeable",""))')"
  MERGE_STATE="$(echo "$INFO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("mergeStateStatus",""))')"
  TITLE="$(echo "$INFO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("title",""))')"
  BASE="$(echo "$INFO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("baseRefName",""))')"

  if [[ "$STATE" != "OPEN" ]]; then
    echo "  PR #$PR ($TITLE): state=$STATE, skip"
    return 1
  fi
  if [[ "$IS_DRAFT" == "True" ]]; then
    echo "  PR #$PR ($TITLE): draft, skip"
    return 1
  fi

  # status checks all green?
  local CHECKS_FAIL CHECKS_PENDING
  CHECKS_FAIL="$(echo "$INFO" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rolls=d.get("statusCheckRollup",[])
fails=[r for r in rolls if r.get("conclusion") in ("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED")]
print(len(fails))')"
  CHECKS_PENDING="$(echo "$INFO" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rolls=d.get("statusCheckRollup",[])
pending=[r for r in rolls if r.get("status") in ("IN_PROGRESS","QUEUED","PENDING","WAITING") or r.get("conclusion") is None]
print(len(pending))')"

  if [[ "$CHECKS_FAIL" -gt 0 ]]; then
    echo "  PR #$PR ($TITLE): $CHECKS_FAIL CI check(s) failing, skip"
    # ci-doctor.sh を nohup spawn して自動修復試行 (conflict-doctor と同パターン)。
    if [[ -x "$REPO_ROOT/claude-executor/bin/ci-doctor.sh" ]]; then
      DOC_LOCK="/tmp/manademia-ci-doctor-pr-${PR}.lock"
      DOC_STATUS_FILE="/tmp/manademia-ci-doctor-pr-${PR}.status"
      DOC_RUNNING=0
      if [[ -f "$DOC_LOCK" ]]; then
        DOC_PID="$(cat "$DOC_LOCK" 2>/dev/null || echo '')"
        if [[ -n "$DOC_PID" ]] && kill -0 "$DOC_PID" 2>/dev/null; then
          DOC_RUNNING=1
        fi
      fi
      if [[ "$DOC_RUNNING" -eq 1 ]]; then
        echo "    └ ci-doctor already working on PR #$PR"
      else
        if [[ -f "$DOC_STATUS_FILE" ]]; then
          DOC_AGE=$(( $(date +%s) - $(stat -c %Y "$DOC_STATUS_FILE" 2>/dev/null || echo 0) ))
          DOC_LAST=$(cat "$DOC_STATUS_FILE" 2>/dev/null || echo '')
          if [[ "$DOC_LAST" == FAILED* ]] && [[ "$DOC_AGE" -lt 7200 ]]; then
            echo "    └ ci-doctor recently FAILED ($DOC_LAST, ${DOC_AGE}s ago), cooldown 2h"
            return 1
          fi
        fi
        echo "    └ spawning ci-doctor for PR #$PR (background)"
        nohup bash "$REPO_ROOT/claude-executor/bin/ci-doctor.sh" "$PR" \
          >> "$REPO_ROOT/logs/ci-doctor-spawn.log" 2>&1 &
        disown
      fi
    fi
    return 1
  fi
  if [[ "$CHECKS_PENDING" -gt 0 ]]; then
    echo "  PR #$PR ($TITLE): $CHECKS_PENDING CI check(s) pending, skip"
    return 1
  fi

  # mergeable?
  if [[ "$MERGEABLE" != "MERGEABLE" ]]; then
    echo "  PR #$PR ($TITLE): mergeable=$MERGEABLE, skip"
    # CONFLICTING の場合は conflict-doctor.sh を一度だけ spawn (自動解決を試行)。
    # 既に doctor 走行中なら何もしない。doctor の status file に最近 FAILED が
    # 書かれてる PR は cooldown (2 時間) を入れて再起動を抑止する。
    if [[ "$MERGEABLE" == "CONFLICTING" ]] \
       && [[ -x "$REPO_ROOT/claude-executor/bin/conflict-doctor.sh" ]]; then
      DOC_LOCK="/tmp/manademia-conflict-doctor-pr-${PR}.lock"
      DOC_STATUS_FILE="/tmp/manademia-conflict-doctor-pr-${PR}.status"
      DOC_RUNNING=0
      if [[ -f "$DOC_LOCK" ]]; then
        DOC_PID="$(cat "$DOC_LOCK" 2>/dev/null || echo '')"
        if [[ -n "$DOC_PID" ]] && kill -0 "$DOC_PID" 2>/dev/null; then
          DOC_RUNNING=1
        fi
      fi
      if [[ "$DOC_RUNNING" -eq 1 ]]; then
        echo "    └ conflict-doctor already working on PR #$PR"
      else
        # 直近 FAILED の cooldown 確認 (status file mtime ≦ 7200s なら skip)
        if [[ -f "$DOC_STATUS_FILE" ]]; then
          DOC_AGE=$(( $(date +%s) - $(stat -c %Y "$DOC_STATUS_FILE" 2>/dev/null || echo 0) ))
          DOC_LAST=$(cat "$DOC_STATUS_FILE" 2>/dev/null || echo '')
          if [[ "$DOC_LAST" == FAILED* ]] && [[ "$DOC_AGE" -lt 7200 ]]; then
            echo "    └ conflict-doctor recently FAILED ($DOC_LAST, ${DOC_AGE}s ago), cooldown 2h"
            return 1
          fi
        fi
        echo "    └ spawning conflict-doctor for PR #$PR (background)"
        nohup bash "$REPO_ROOT/claude-executor/bin/conflict-doctor.sh" "$PR" \
          >> "$REPO_ROOT/logs/conflict-doctor-spawn.log" 2>&1 &
        disown
      fi
    fi
    return 1
  fi

  # mergeStateStatus が CLEAN / HAS_HOOKS なら OK、それ以外 (BLOCKED, DIRTY, BEHIND, ...) は skip
  case "$MERGE_STATE" in
    CLEAN|HAS_HOOKS|UNSTABLE)
      ;;
    BEHIND)
      # base から遅れている場合 update branch を試みる (admin 権限あれば)
      echo "  PR #$PR ($TITLE): BEHIND, attempting branch update..."
      gh pr update-branch "$PR" 2>/dev/null || true
      echo "  PR #$PR ($TITLE): mergeStateStatus=BEHIND, skip (re-check next loop)"
      return 1 ;;
    *)
      echo "  PR #$PR ($TITLE): mergeStateStatus=$MERGE_STATE, skip"
      return 1 ;;
  esac

  # base ブランチ確認 (main / master のみ許可、それ以外は skip)
  case "$BASE" in
    main|master|develop) ;;
    *)
      echo "  PR #$PR ($TITLE): base=$BASE not main-like, skip"
      return 1 ;;
  esac

  echo "  PR #$PR ($TITLE): GREEN, merging..."
  # bug #1 / #8 fix: dispatcher が lane-queue.md を編集中に gh pr merge が
  # 内部 checkout を試みると "Your local changes ... would be overwritten" で失敗していた。
  # 解決策: 一時 stash で working tree を綺麗にしてから merge、終わったら pop。
  local stashed=0
  if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
    if git -C "$REPO_ROOT" stash push -u -m "merge-when-green auto-stash $(date +%s)" >/dev/null 2>&1; then
      stashed=1
      echo "    [stash] working tree stashed before merge"
    fi
  fi

  # 多段 fallback: --merge → --squash → --rebase → --auto --merge (最後の砦)
  local out rc method
  for method in --merge --squash --rebase; do
    out="$(gh pr merge "$PR" "$method" --delete-branch 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$out" | sed 's/^/    /'
      echo "  PR #$PR ($TITLE): ✓ merged ($method)"
      [[ "$stashed" -eq 1 ]] && git -C "$REPO_ROOT" stash pop --quiet 2>/dev/null || true
      cleanup_local_after_merge "$PR"
      kick_production_refresh "$PR"
      return 0
    fi
    # 「既に merged」は success と等価扱い (GitHub auto-merge が先に処理した等)
    # → fallback chain を回す意味がないので cleanup hook 呼んで return
    if echo "$out" | grep -q "was already merged"; then
      echo "$out" | sed 's/^/    /'
      echo "  PR #$PR ($TITLE): ✓ already merged (treat as success)"
      [[ "$stashed" -eq 1 ]] && git -C "$REPO_ROOT" stash pop --quiet 2>/dev/null || true
      cleanup_local_after_merge "$PR"
      kick_production_refresh "$PR"
      return 0
    fi
    echo "  PR #$PR ($TITLE): $method failed (rc=$rc):"
    echo "$out" | sed 's/^/    /'
  done

  # 最後の砦: GitHub の auto-merge を enable (CI green 時に GitHub 側で自動 merge)
  echo "  PR #$PR ($TITLE): all immediate merge methods failed, enabling auto-merge..."
  out="$(gh pr merge "$PR" --auto --merge --delete-branch 2>&1)"
  rc=$?
  echo "$out" | sed 's/^/    /'
  [[ "$stashed" -eq 1 ]] && git -C "$REPO_ROOT" stash pop --quiet 2>/dev/null || true
  if [[ $rc -eq 0 ]]; then
    echo "  PR #$PR ($TITLE): ✓ auto-merge enabled (GitHub will merge when ready)"
    return 0
  fi
  echo "  PR #$PR ($TITLE): all merge methods failed (rc=$rc)"
  return 2
}

# merge 直後に production server (port 3010) を最新 main で再 build + restart。
# nohup で background 起動、merge-when-green の本体フローは block しない。
# script 自身が lockfile で同時実行防止する。
kick_production_refresh() {
  local pr="$1"
  local script="$REPO_ROOT/scripts/refresh-production-server.sh"
  if [[ ! -x "$script" ]]; then
    return 0  # script 無し / 実行権限無し は静かに skip
  fi
  echo "  PR #$pr: kicking production server refresh (background)"
  nohup bash "$script" >> "$REPO_ROOT/logs/refresh-production-kick.log" 2>&1 &
  disown
}

# merge 後に該当する local worktree + branch を削除する。
# 安全規則: uncommitted changes or unpushed commits があれば skip (作業中扱い)。
# remote 側は gh pr merge --delete-branch で既に削除されている前提。
cleanup_local_after_merge() {
  local pr="$1"
  local head_ref wt_path uncommitted unpushed
  head_ref="$(gh pr view "$pr" --json headRefName -q '.headRefName' 2>/dev/null)"
  [[ -z "$head_ref" ]] && return 0

  # local branch が存在しなければ何もしない
  if ! git -C "$REPO_ROOT" rev-parse --verify "refs/heads/$head_ref" >/dev/null 2>&1; then
    return 0
  fi

  # 関連 worktree path を git worktree list の porcelain から逆引き
  wt_path="$(git -C "$REPO_ROOT" worktree list --porcelain | awk -v br="refs/heads/$head_ref" '
    /^worktree / { p=$2 }
    /^branch /   { if ($2==br) { print p; exit } }
  ')"

  if [[ -n "$wt_path" && -d "$wt_path" ]]; then
    uncommitted="$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l)"
    unpushed="$(git -C "$wt_path" log '@{u}..HEAD' --oneline 2>/dev/null | wc -l)"
    if [[ "$uncommitted" -gt 0 || "$unpushed" -gt 0 ]]; then
      echo "    PR #$pr: skip local cleanup (uncommitted=$uncommitted, unpushed=$unpushed)"
      return 0
    fi
    git -C "$REPO_ROOT" worktree remove "$wt_path" 2>&1 | sed 's/^/    /'
  fi

  git -C "$REPO_ROOT" branch -D "$head_ref" 2>&1 | sed 's/^/    /'
}

# main loop
# Quiet mode: "no open PRs" / "merged=0 skipped=N" の連続出力を抑制。
# 状態が前回と同じならスキップし、10 分ごとに 1 回だけ idle summary 出力。
LAST_STATE_KEY=""
LAST_LOG_AT=0
IDLE_HEARTBEAT_SEC=600  # 10 分

emit_log() {
  local key="$1"
  local msg="$2"
  local now
  now=$(date +%s)
  if [[ "$key" == "$LAST_STATE_KEY" ]]; then
    # 同じ状態が続いている: 10 分経過時のみ heartbeat 出力
    if (( now - LAST_LOG_AT >= IDLE_HEARTBEAT_SEC )); then
      echo "[$(date +%H:%M:%S)] $msg (still)"
      LAST_LOG_AT=$now
    fi
  else
    echo "[$(date +%H:%M:%S)] $msg"
    LAST_STATE_KEY=$key
    LAST_LOG_AT=$now
  fi
}

run_one_pass() {
  local PRS
  if [[ -n "$PR_FILTER" ]]; then
    PRS="$PR_FILTER"
  else
    PRS="$(gh pr list --state open --limit 50 --json number --jq '.[].number' 2>/dev/null | tr '\n' ' ')"
  fi
  if [[ -z "$PRS" ]]; then
    emit_log "idle" "no open PRs"
    return 0
  fi

  # PR がある時は always 出力 (= 状態変化 / 重要 event を逃さない)
  echo "[$(date +%H:%M:%S)] checking PR(s): $PRS"
  LAST_STATE_KEY="active"   # idle 状態をリセット
  local MERGED=0 SKIPPED=0
  for PR in $PRS; do
    if check_and_merge "$PR"; then
      MERGED=$((MERGED + 1))
    else
      SKIPPED=$((SKIPPED + 1))
    fi
  done
  echo "[$(date +%H:%M:%S)] merged=$MERGED skipped=$SKIPPED"
}

trap 'release_lock; exit 130' INT TERM

# bug #4 fix: 起動時の catch-up cleanup
# 過去 watcher (cleanup hook 無し or merge command failed パス) で残った merged 済 worktree を
# 一括 cleanup する。新 watcher 起動時に 1 回だけ走る。
catchup_cleanup_on_startup() {
  echo "[$(date +%H:%M:%S)] catchup cleanup: scanning local worktrees for merged-but-not-cleaned..."
  local count=0
  while IFS= read -r line; do
    [[ "$line" =~ ^worktree[[:space:]]+(.+)$ ]] || continue
    local wt_path="${BASH_REMATCH[1]}"
    [[ "$wt_path" == "$REPO_ROOT" ]] && continue
    [[ -d "$wt_path" ]] || continue
    local wt_branch
    wt_branch="$(git -C "$wt_path" branch --show-current 2>/dev/null)"
    [[ -z "$wt_branch" ]] && continue
    # PR 状態を check
    local pr_state
    pr_state="$(gh pr list --head "$wt_branch" --state all --limit 1 --json state --jq '.[0].state' 2>/dev/null || echo '')"
    if [[ "$pr_state" == "MERGED" ]]; then
      local uncommitted unpushed
      uncommitted="$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l)"
      unpushed="$(git -C "$wt_path" log '@{u}..HEAD' --oneline 2>/dev/null | wc -l)"
      if [[ "$uncommitted" -gt 0 || "$unpushed" -gt 0 ]]; then
        echo "    skip $wt_branch (uncommitted=$uncommitted unpushed=$unpushed)"
        continue
      fi
      echo "    cleanup: $wt_branch ($wt_path)"
      git -C "$REPO_ROOT" worktree remove "$wt_path" 2>&1 | sed 's/^/      /' || true
      git -C "$REPO_ROOT" branch -D "$wt_branch" 2>&1 | sed 's/^/      /' || true
      count=$((count + 1))
    fi
  done < <(git -C "$REPO_ROOT" worktree list --porcelain)
  echo "[$(date +%H:%M:%S)] catchup cleanup: $count worktree(s) removed"
}

if [[ "$WATCH_MODE" -eq 1 ]]; then
  acquire_lock
  echo "[$(date +%H:%M:%S)] watch mode: polling every ${WATCH_INTERVAL_SEC}s (Ctrl+C to stop)"
  catchup_cleanup_on_startup
  while true; do
    run_one_pass
    sleep "$WATCH_INTERVAL_SEC"
  done
  release_lock
else
  run_one_pass
fi
