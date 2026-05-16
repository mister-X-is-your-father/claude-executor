#!/usr/bin/env bash
# claude-executor/bin/consumer.sh
#
# GitHub issue 1 件を Sonnet / Haiku / Opus (規模で分岐) sub-process で
# end-to-end 消化する (= worktree 作成 → 実装 → verify → PR → close)。
# ci-doctor.sh と同じ pattern (lockfile / status / cooldown / model fallback)。
#
# Usage:
#   claude-executor/bin/consumer.sh <ISSUE_NUMBER>
#
# 動作:
#   1. issue 内容取得 (gh issue view)
#   2. triage: 法務 / Long-term / priority/low / 既に in-flight PR ある → skip
#   3. label / body から「kind」判定 (docs-trivial / docs-detailed / impl / complex)
#   4. kind に応じて model 選定 (Haiku / Sonnet / Opus)
#   5. lockfile (/tmp/${PROJECT}-issue-consumer.lock) で並列禁止 (1 体まで)
#   6. fresh worktree 作成 (= /tmp/${PROJECT}-issue-N/)
#   7. claude --print で end-to-end (Sonnet が PR 作成 + push まで)
#   8. rule-based verify: docs-only diff なら build skip、code touch なら pnpm build 必須
#   9. status file (/tmp/${PROJECT}-issue-consumer-<N>.status) に OK / FAILED 記録
#
# 安全規則:
#   - 同時 1 体まで (global lockfile)
#   - main / master 直接 push 禁止 (= worktree branch のみ)
#   - --no-verify / --force 禁止
#   - 不明な issue は素直に FAILED:unknown で escalate
#   - 直近 FAILED は cooldown 24h (= 無限再試行防止)

set -uo pipefail

ISSUE_NUM="${1:-}"
if [[ -z "$ISSUE_NUM" || ! "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <ISSUE_NUMBER>" >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${EXECUTOR_PROJECT_NAME:-manademia}"
GLOBAL_LOCKFILE="/tmp/${PROJECT}-issue-consumer.lock"
STATUS_FILE="/tmp/${PROJECT}-issue-consumer-${ISSUE_NUM}.status"
LOG_DIR="$REPO/logs"
LOG_FILE="$LOG_DIR/issue-consumer-${ISSUE_NUM}-$(date +%Y%m%d-%H%M%S).log"
TIMEOUT_SEC="${ISSUE_CONSUMER_TIMEOUT_SEC:-2400}"   # 40 min default

# v2: elapsed_sec を正確に取るため script 起動時刻を保持
START_TS=$(date +%s)

mkdir -p "$LOG_DIR"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# === Lock (global、1 体のみ) ===
if [[ -f "$GLOBAL_LOCKFILE" ]]; then
  OLD_PID="$(cat "$GLOBAL_LOCKFILE" 2>/dev/null || echo '')"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    log "another issue-consumer is running (PID=$OLD_PID), exit"
    exit 0
  fi
  rm -f "$GLOBAL_LOCKFILE"
fi
echo "$$" > "$GLOBAL_LOCKFILE"
trap 'rm -f "$GLOBAL_LOCKFILE"' EXIT

# === Cooldown (v2: failure 種別で長さを変える) ===
# - rate-limit / overload: 1 時間 (= API 復旧後に retry)
# - quality-gate / no-status / unknown: 24 時間 (= 根本原因要)
# - timeout: 6 時間 (= 一時的な claude crash 等)
if [[ -f "$STATUS_FILE" ]]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$STATUS_FILE" 2>/dev/null || echo 0) ))
  LAST=$(cat "$STATUS_FILE" 2>/dev/null || echo '')
  if [[ "$LAST" == FAILED* ]]; then
    case "$LAST" in
      *rate-limit*|*overload*|*usage-limit*) COOLDOWN=3600 ;;     # 1h
      *timeout*)                              COOLDOWN=21600 ;;    # 6h
      *)                                      COOLDOWN=86400 ;;    # 24h
    esac
    if [[ "$AGE" -lt "$COOLDOWN" ]]; then
      log "issue #$ISSUE_NUM recently FAILED ($LAST, ${AGE}s ago), cooldown ${COOLDOWN}s"
      exit 0
    fi
  fi
fi

# === Issue 情報取得 ===
ISSUE_JSON="$(gh issue view "$ISSUE_NUM" --json number,title,body,labels,milestone,state 2>/dev/null || echo '')"
if [[ -z "$ISSUE_JSON" ]]; then
  echo "FAILED:issue-not-found" > "$STATUS_FILE"
  log "ERROR: issue #$ISSUE_NUM not found"
  exit 1
fi

ISSUE_STATE="$(echo "$ISSUE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))')"
if [[ "$ISSUE_STATE" != "OPEN" ]]; then
  log "issue #$ISSUE_NUM is $ISSUE_STATE, skip"
  echo "OK:not-open" > "$STATUS_FILE"
  exit 0
fi

TITLE="$(echo "$ISSUE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("title",""))')"
LABELS="$(echo "$ISSUE_JSON" | python3 -c 'import json,sys;print(" ".join(l["name"] for l in json.load(sys.stdin).get("labels",[])))')"
MILESTONE="$(echo "$ISSUE_JSON" | python3 -c 'import json,sys;m=json.load(sys.stdin).get("milestone");print(m["title"] if m else "")')"

log "issue #$ISSUE_NUM: $TITLE"
log "  labels: $LABELS"
log "  milestone: $MILESTONE"

# === Triage: skip 条件 (env でカスタマイズ可) ===
# EXECUTOR_SKIP_LABELS: comma-separated label list (default = manademia 互換)
# EXECUTOR_SKIP_MILESTONES: comma-separated milestone title list
EXECUTOR_SKIP_LABELS="${EXECUTOR_SKIP_LABELS:-area/legal,priority/low,consumer-skip}"
EXECUTOR_SKIP_MILESTONES="${EXECUTOR_SKIP_MILESTONES:-Long-term (Phase 11+)}"

SKIP_REASON=""
# label match (= 部分一致でなく単語一致でも安全に label 文字列内に含まれるか)
IFS=',' read -ra _SKIP_LABEL_ARR <<< "$EXECUTOR_SKIP_LABELS"
for _sl in "${_SKIP_LABEL_ARR[@]}"; do
  _sl_trim="$(echo "$_sl" | sed 's/^ *//;s/ *$//')"
  [[ -z "$_sl_trim" ]] && continue
  if [[ "$LABELS" == *"$_sl_trim"* ]]; then
    SKIP_REASON="$_sl_trim (env: EXECUTOR_SKIP_LABELS)"
    break
  fi
done
# milestone match (= 完全一致)
if [[ -z "$SKIP_REASON" ]]; then
  IFS=',' read -ra _SKIP_MS_ARR <<< "$EXECUTOR_SKIP_MILESTONES"
  for _sm in "${_SKIP_MS_ARR[@]}"; do
    _sm_trim="$(echo "$_sm" | sed 's/^ *//;s/ *$//')"
    [[ -z "$_sm_trim" ]] && continue
    if [[ "$MILESTONE" == "$_sm_trim" ]]; then
      SKIP_REASON="milestone:$_sm_trim (env: EXECUTOR_SKIP_MILESTONES)"
      break
    fi
  done
fi

if [[ -n "$SKIP_REASON" ]]; then
  echo "OK:skipped:$SKIP_REASON" > "$STATUS_FILE"
  log "SKIP: $SKIP_REASON"
  exit 0
fi

# === 既に open PR があるか確認 (= in-flight) ===
EXISTING_PR="$(gh pr list --state open --search "Closes #${ISSUE_NUM} in:body" --json number 2>/dev/null | python3 -c 'import json,sys;rs=json.load(sys.stdin);print(rs[0]["number"] if rs else "")')"
if [[ -n "$EXISTING_PR" ]]; then
  echo "OK:in-flight:PR#$EXISTING_PR" > "$STATUS_FILE"
  log "SKIP: in-flight PR #$EXISTING_PR exists"
  exit 0
fi

# === Kind / Model 判定 ===
KIND="impl"   # default
if [[ "$LABELS" == *"type/docs"* ]]; then
  if [[ "$LABELS" == *"priority/high"* || "$LABELS" == *"priority/critical"* ]]; then
    KIND="docs-detailed"
  else
    KIND="docs-trivial"
  fi
elif [[ "$LABELS" == *"type/refactor"* && "$LABELS" == *"area/tech-debt"* ]]; then
  KIND="docs-detailed"   # 多くは docs ベースの戦略書き
elif [[ "$LABELS" == *"priority/critical"* || "$LABELS" == *"type/feature"* ]]; then
  KIND="impl"
fi

case "$KIND" in
  docs-trivial)  MODEL="${ISSUE_CONSUMER_MODEL_TRIVIAL:-claude-haiku-4-5-20251001}" ;;
  docs-detailed) MODEL="${ISSUE_CONSUMER_MODEL_DETAILED:-claude-sonnet-4-6}" ;;
  impl)          MODEL="${ISSUE_CONSUMER_MODEL_IMPL:-claude-sonnet-4-6}" ;;
  complex)       MODEL="${ISSUE_CONSUMER_MODEL_COMPLEX:-claude-opus-4-7}" ;;
esac
FALLBACK_MODEL="${ISSUE_CONSUMER_MODEL_FALLBACK:-claude-opus-4-7}"

log "  kind: $KIND, model: $MODEL"

# === Worktree 作成 ===
WORKTREE_DIR="/tmp/${PROJECT}-issue-${ISSUE_NUM}"
BRANCH_NAME="issue/${ISSUE_NUM}"

# 既存 cleanup
git -C "$REPO" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
rm -rf "$WORKTREE_DIR"
git -C "$REPO" branch -D "$BRANCH_NAME" 2>/dev/null || true

# 新規作成 (main から)
git -C "$REPO" fetch origin main --quiet 2>&1 | head -2 | tee -a "$LOG_FILE"
git -C "$REPO" worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" origin/main 2>&1 | tee -a "$LOG_FILE"
if [[ ! -d "$WORKTREE_DIR" ]]; then
  echo "FAILED:worktree-create" > "$STATUS_FILE"
  log "ERROR: worktree creation failed"
  exit 1
fi
log "  worktree: $WORKTREE_DIR"
log "  branch: $BRANCH_NAME"

# === Prompt 組立 ===
# Slim: CLAUDE.md / AGENTS.md 全文 load しない、routing pointer のみ
ISSUE_BODY="$(echo "$ISSUE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("body",""))')"

PROMPT_BODY=$(cat <<EOF
あなたは ${PROJECT} リポジトリの issue 自動消化 sub-agent です。
GitHub issue #${ISSUE_NUM} を end-to-end で解決し、PR を作成してください。

## 作業ディレクトリ
${WORKTREE_DIR} (= 既に main から fresh worktree を作成済、branch=${BRANCH_NAME})

## Issue 情報
Title: ${TITLE}
Labels: ${LABELS}
Kind 判定: ${KIND}

### Body
${ISSUE_BODY}

## 手順

1. \`cd ${WORKTREE_DIR}\` で worktree に入る
2. issue body に書かれた「成果物」「方向」「規模」を理解する
3. 実装 (= ファイル作成 / 編集):
   - docs-trivial / docs-detailed の場合: docs/playbooks/ または runbooks/ に markdown 追加が中心
   - impl の場合: lib / app / components を編集、test 追加
   - **既存ファイルを編集する前に必ず Read で確認**、書く前に grep で既存類似 docs / code がないか確認
4. **verify (kind 別)**:
   - docs-only diff (\`docs/\` \`runbooks/\` のみ): \`pnpm typecheck\` のみ (lint/format/build 不要)
   - 任意ファイル touch (\`lib/\` \`app/\` \`components/\` 等): \`pnpm typecheck && pnpm lint && pnpm format:check && pnpm build\` 全て必須 (= use server 違反等を build で catch)
5. commit (message: \`<scope>(<area>): <description> (#${ISSUE_NUM})\` + Co-Authored-By)
6. \`git push -u origin ${BRANCH_NAME}\`
7. \`gh pr create --head ${BRANCH_NAME} --base main\` で PR 作成、body に \`Closes #${ISSUE_NUM}\` を含める
8. \`/tmp/${PROJECT}-issue-consumer-${ISSUE_NUM}.status\` に \`OK:PR#<N>\` を 1 行で書いて exit

## 禁止 / 制約

- main / master への直接 push 禁止
- 他 worktree / main worktree への touch 禁止 (\`cd /home/neo/manademia\` などしない)
- --no-verify / --force / --skip-checks 禁止
- pnpm verify 失敗のまま push 禁止
- 不明な要求 / 法的 review 要 / 大規模 spec で完結不可能と判断したら \`FAILED:<reason>\` を status file に書いて素直に escalate
- 本 issue 以外の issue を触らない、他 PR に影響しない

## 完了基準

status file に \`OK:PR#<N>\` または \`FAILED:<phase>:<reason>\` を 1 行で書く。
${TIMEOUT_SEC} 秒経過で claude プロセスは打ち切られる。
EOF
)

rm -f "$STATUS_FILE"

run_claude_attempt() {
  local model="$1" label="$2"
  log "$label invoking claude (model=$model)"
  timeout --signal=TERM --kill-after=30s "${TIMEOUT_SEC}s" \
    claude --model "$model" --dangerously-skip-permissions --print "$PROMPT_BODY" \
    2>&1 | tee -a "$LOG_FILE"
  return ${PIPESTATUS[0]}
}

is_rate_limited_log() {
  grep -qiE 'rate[ _-]?limit|too many requests|usage[ _-]?limit|quota_exceeded|rate_limit_error|insufficient_quota|429 status|model.{0,10}overload' "$LOG_FILE" 2>/dev/null
}

run_claude_attempt "$MODEL" "[primary:$KIND]"
RC=$?
if [[ "$RC" -ne 0 ]] && [[ "$MODEL" != "$FALLBACK_MODEL" ]] && is_rate_limited_log; then
  log "WARN: primary $MODEL rate-limited, fallback to $FALLBACK_MODEL"
  run_claude_attempt "$FALLBACK_MODEL" "[fallback]"
  RC=$?
fi

STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo 'FAILED:no-status')"
log "result: $STATUS  (claude rc=$RC)"

# === Quality gate v2 (= rule-based verify、安全網) ===
quality_gate_check() {
  local pr_num="$1"
  [[ -z "$pr_num" ]] && return 0

  local pr_json
  pr_json="$(gh pr view "$pr_num" --json additions,deletions,body,files,commits 2>/dev/null || echo '')"
  if [[ -z "$pr_json" ]]; then
    log "QUALITY GATE FAIL: cannot fetch PR info"
    return 1
  fi

  # gate 1: diff size cap (= 1 PR 1500 行以下)
  local diff_stat
  diff_stat="$(echo "$pr_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["additions"]+d["deletions"])')"
  if [[ -n "$diff_stat" && "$diff_stat" =~ ^[0-9]+$ && "$diff_stat" -gt 1500 ]]; then
    log "QUALITY GATE FAIL: diff too large ($diff_stat lines > 1500)"
    return 1
  fi

  # gate 2: PR body に Closes #N
  if ! echo "$pr_json" | python3 -c "import json,sys;b=json.load(sys.stdin).get('body','') or '';import re;exit(0 if re.search(r'[Cc]loses?\s+#${ISSUE_NUM}\b',b) else 1)" 2>/dev/null; then
    log "QUALITY GATE FAIL: PR body missing 'Closes #${ISSUE_NUM}'"
    return 1
  fi

  # gate 3: 危険ファイルに触ってないか (= migrations / .env / secrets を意図せず変更)
  local dangerous_files
  dangerous_files="$(echo "$pr_json" | python3 -c '
import json, sys, re
fs = json.load(sys.stdin).get("files",[])
DANGER = (
    re.compile(r"^supabase/migrations/"),  # migration 新規・改変は明示 spec が要る
    re.compile(r"^\.env(\..*)?$"),         # 秘密値
    re.compile(r"^scripts/refresh-production-server\.sh$"),
    re.compile(r"^scripts/merge-when-green\.sh$"),
    re.compile(r"^\.husky/"),
)
hits = [f["path"] for f in fs if any(p.search(f["path"]) for p in DANGER)]
print("\n".join(hits))
')"
  if [[ -n "$dangerous_files" ]]; then
    log "QUALITY GATE WARN: dangerous files touched:"
    echo "$dangerous_files" | sed 's/^/    /' | tee -a "$LOG_FILE"
    # warn のみ、reject はしない (= migration 系 issue では正当に触る場合あり)
  fi

  # gate 4: 最低 1 commit (= 空 PR を弾く)
  local commit_count
  commit_count="$(echo "$pr_json" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("commits",[])))')"
  if [[ "$commit_count" -lt 1 ]]; then
    log "QUALITY GATE FAIL: empty PR (0 commits)"
    return 1
  fi

  # gate 5: PR body 必須 section (= 最低限の説明)
  if echo "$pr_json" | python3 -c "import json,sys;b=json.load(sys.stdin).get('body','') or '';exit(0 if len(b.strip())>=30 else 1)" 2>/dev/null; then
    : # OK
  else
    log "QUALITY GATE FAIL: PR body too short (<30 chars)"
    return 1
  fi

  log "quality gate: PASS (diff=$diff_stat lines, commits=$commit_count)"
  return 0
}

# === Telemetry: per-run JSON log ===
write_telemetry() {
  local pr_num="$1" final_status="$2"
  local elapsed_sec
  elapsed_sec=$(( $(date +%s) - START_TS ))
  printf '{"issue":%s,"kind":"%s","model":"%s","status":"%s","pr":"%s","elapsed_sec":%s,"ts":"%s"}\n' \
    "$ISSUE_NUM" "$KIND" "$MODEL" "$final_status" "${pr_num:-}" "$elapsed_sec" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "$LOG_DIR/consumer-stats.jsonl"
}

# === cleanup worktree (= 成功時) / 失敗時は残す (デバッグ用) ===
case "$STATUS" in
  OK:PR*)
    PR_NUM_STR="${STATUS#OK:PR#}"
    PR_NUM_STR="${PR_NUM_STR%% *}"
    if quality_gate_check "$PR_NUM_STR"; then
      log "PR #$PR_NUM_STR created + quality gate PASS, watcher will auto-merge"
      write_telemetry "$PR_NUM_STR" "OK"
      exit 0
    else
      log "PR #$PR_NUM_STR created but quality gate FAIL, marking for manual review"
      gh pr edit "$PR_NUM_STR" --add-label "needs-manual-review" 2>/dev/null || true
      gh pr comment "$PR_NUM_STR" --body "🤖 issue-consumer: quality gate failed (diff size cap / Closes link 検出)、手動レビュー要" 2>/dev/null || true
      echo "FAILED:quality-gate:PR#${PR_NUM_STR}" > "$STATUS_FILE"
      write_telemetry "$PR_NUM_STR" "FAILED:quality-gate"
      exit 1
    fi
    ;;
  OK:*)
    git -C "$REPO" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    git -C "$REPO" branch -D "$BRANCH_NAME" 2>/dev/null || true
    write_telemetry "" "$STATUS"
    exit 0
    ;;
  *)
    log "FAILED: leaving worktree $WORKTREE_DIR for debug"
    write_telemetry "" "$STATUS"
    exit 1
    ;;
esac
