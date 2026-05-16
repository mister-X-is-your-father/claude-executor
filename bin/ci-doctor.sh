#!/usr/bin/env bash
# claude-executor/bin/ci-doctor.sh
#
# PR の CI fail を Claude (Sonnet 4.6 / Opus 4.7 fallback) に修復させる。
# merge-when-green.sh が `checks_fail > 0` を検出した時に spawn する想定。
# conflict-doctor.sh と同じパターン (lockfile / status / cooldown / GitHub PR comment)。
#
# Usage:
#   claude-executor/bin/ci-doctor.sh <PR_NUMBER>
#
# 動作:
#   1. PR の branch / worktree を特定
#   2. lockfile (/tmp/manademia-ci-doctor-pr-<N>.lock) で多重起動防止
#   3. 該当 worktree で gh pr checks <N> --json で fail check 取得
#   4. Claude を `--print` で起動。prompt で:
#      - failed CI logs を gh run view で取得
#      - 既知パターン (format / lint / typecheck / migration / test) に分類
#      - パターン別 fix を実装 + commit + push
#      - 不明な場合は FAILED:unknown で escalate
#   5. status file に OK / FAILED:<phase>:<reason> 記録
#   6. FAILED 時は gh pr comment で詳細投稿 + label "needs-manual-ci-fix" 付与
#
# 安全規則:
#   - main / master への直接操作禁止
#   - --no-verify / --force 使用禁止
#   - 不明な CI fail は素直に escalate (適当に commit しない)
#   - 同 PR に対し並行 doctor を起動しない (lockfile)
#   - 直近 FAILED の cooldown 2 時間 (無限再試行防止)

set -uo pipefail

PR_NUM="${1:-}"
if [[ -z "$PR_NUM" || ! "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <PR_NUMBER>" >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCKFILE="/tmp/manademia-ci-doctor-pr-${PR_NUM}.lock"
STATUS_FILE="/tmp/manademia-ci-doctor-pr-${PR_NUM}.status"
LOG_DIR="$REPO/logs"
LOG_FILE="$LOG_DIR/ci-doctor-pr-${PR_NUM}-$(date +%Y%m%d-%H%M%S).log"
TIMEOUT_SEC="${CI_DOCTOR_TIMEOUT_SEC:-1800}"
PRIMARY_MODEL="${CI_DOCTOR_MODEL_PRIMARY:-claude-sonnet-4-6}"
FALLBACK_MODEL="${CI_DOCTOR_MODEL_FALLBACK:-claude-opus-4-7}"

mkdir -p "$LOG_DIR"

# Cleanup: lockfile + ephemeral worktree (auto-create した時のみ remove)
WORKTREE_CREATED=false
WORKTREE_DIR=""
cleanup() {
  rm -f "$LOCKFILE"
  if [[ "$WORKTREE_CREATED" == "true" && -n "$WORKTREE_DIR" && -d "$WORKTREE_DIR" ]]; then
    echo "[$(date +%H:%M:%S)] cleaning up ephemeral worktree $WORKTREE_DIR" | tee -a "$LOG_FILE" 2>/dev/null || true
    git -C "$REPO" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
    git -C "$REPO" worktree prune 2>/dev/null || true
  fi
}

# Lock check
if [[ -f "$LOCKFILE" ]]; then
  OLD_PID="$(cat "$LOCKFILE" 2>/dev/null || echo '')"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[$(date +%H:%M:%S)] ci-doctor already running for PR #$PR_NUM (PID=$OLD_PID), exit" | tee -a "$LOG_FILE"
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo "$$" > "$LOCKFILE"
trap cleanup EXIT

# PR 情報
PR_INFO="$(gh pr view "$PR_NUM" --json number,title,headRefName,statusCheckRollup 2>/dev/null || echo '')"
if [[ -z "$PR_INFO" ]]; then
  echo "FAILED:pr-not-found" > "$STATUS_FILE"
  exit 1
fi
BRANCH="$(echo "$PR_INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("headRefName",""))')"
TITLE="$(echo "$PR_INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("title",""))')"

# fail check 数確認
FAIL_COUNT="$(echo "$PR_INFO" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rolls=d.get("statusCheckRollup",[])
fails=[r for r in rolls if r.get("conclusion") in ("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED")]
print(len(fails))')"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "[$(date +%H:%M:%S)] PR #$PR_NUM has no failing CI checks, nothing to do" | tee -a "$LOG_FILE"
  echo "OK:no-fail" > "$STATUS_FILE"
  exit 0
fi

echo "[$(date +%H:%M:%S)] ci-doctor starting" | tee -a "$LOG_FILE"
echo "  PR        : #$PR_NUM ($TITLE)" | tee -a "$LOG_FILE"
echo "  branch    : $BRANCH" | tee -a "$LOG_FILE"
echo "  fails     : $FAIL_COUNT check(s)" | tee -a "$LOG_FILE"

# worktree 解決
WORKTREE_DIR="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk -v b="$BRANCH" '
  /^worktree / {wt=$2}
  /^branch / {if ($2 == "refs/heads/" b) print wt}
')"
if [[ -z "$WORKTREE_DIR" || ! -d "$WORKTREE_DIR" ]]; then
  # 既存 worktree なしの場合は ephemeral worktree を auto-create。
  # auto-create された worktree は EXIT 時に cleanup() が remove する。
  # 主目的: 私が手動で push した PR、consumer 完了後に worktree GC された PR、
  # 別 host で作業した PR 等を、ci-doctor 単独で resolve 可能にする。
  echo "[$(date +%H:%M:%S)] no existing worktree for '$BRANCH', creating ephemeral worktree..." | tee -a "$LOG_FILE"
  WORKTREE_DIR="/tmp/manademia-ci-doctor-wt-pr-${PR_NUM}"
  if [[ -d "$WORKTREE_DIR" ]]; then
    git -C "$REPO" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
    rm -rf "$WORKTREE_DIR"
  fi
  if ! git -C "$REPO" fetch origin "$BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    echo "FAILED:fetch-branch" > "$STATUS_FILE"
    echo "[$(date +%H:%M:%S)] ERROR: cannot fetch branch '$BRANCH' from origin" | tee -a "$LOG_FILE"
    exit 1
  fi
  if ! git -C "$REPO" worktree add -B "$BRANCH" "$WORKTREE_DIR" "origin/$BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    echo "FAILED:worktree-create" > "$STATUS_FILE"
    echo "[$(date +%H:%M:%S)] ERROR: cannot create worktree at '$WORKTREE_DIR'" | tee -a "$LOG_FILE"
    exit 1
  fi
  git -C "$WORKTREE_DIR" branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
  WORKTREE_CREATED=true
fi
echo "  worktree  : $WORKTREE_DIR (ephemeral=$WORKTREE_CREATED)" | tee -a "$LOG_FILE"

PROMPT_BODY=$(cat <<EOF
あなたは manademia リポジトリの CI fail 自動修復 sub-agent です。
PR #${PR_NUM} (branch: ${BRANCH}) の CI を green にしてください。

## 作業ディレクトリ
${WORKTREE_DIR} (直接 cd して作業、他 worktree / main worktree は触らない)

## 手順

1. \`cd ${WORKTREE_DIR}\` してから \`git status -sb\` で現状確認 (clean であるべき)
2. \`gh pr checks ${PR_NUM}\` で failed check 一覧を取得
3. 各 fail について \`gh run view <run-id> --log-failed\` でログ取得
4. **既知パターンに分類**:
   - **format**: \`pnpm format\` で自動修正、stage + commit
   - **lint**: \`pnpm lint --fix\` で自動修正、残った warnings は spec の owner files の範囲で手動修正
   - **typecheck**: ログのエラー行をピンポイント修正、再 typecheck で確認
   - **test (unit)**: 失敗 test を Read で開き、原因解析。本実装側のバグなら fix、test 側の前提変化なら test 更新
   - **migration**: ログ確認、SQL 構文 / 番号衝突 / RLS issue を修正
   - **e2e**: skip 推奨 (環境依存多すぎて自動修復は危険)、FAILED:e2e-skip で escalate
   - **不明** / 上記以外: FAILED:unknown:<short reason> で escalate
5. 修正 commit (message: \`fix(ci): <pattern> — <short description>\`)
6. \`pnpm verify\` でローカル green 確認
7. \`git push\` (該当 branch のみ)
8. \`/tmp/manademia-ci-doctor-pr-${PR_NUM}.status\` に \`OK\` を書いて exit
9. push 後 GitHub Actions の再走を待つのは scripts の役目ではない (watcher が次周で確認)

## 禁止
- pnpm verify 失敗のまま push
- main / master への直接操作
- --no-verify / --force / --skip-checks (CI fail を飛ばさない、修正する)
- 他 PR / 他 worktree への touch
- 「適当に修正してみる」(不明なら FAILED:unknown で素直に escalate)

## 完了基準
status file に \`OK\` (push 成功) or \`FAILED:<phase>:<reason>\` (修復不能) を 1 行で。
${TIMEOUT_SEC} 秒経過で claude プロセスは打ち切られます。
EOF
)

rm -f "$STATUS_FILE"

run_claude_attempt() {
  local model="$1" label="$2"
  echo "[$(date +%H:%M:%S)] $label invoking claude (model=$model)" | tee -a "$LOG_FILE"
  timeout --signal=TERM --kill-after=30s "${TIMEOUT_SEC}s" \
    claude --model "$model" --dangerously-skip-permissions --print "$PROMPT_BODY" \
    2>&1 | tee -a "$LOG_FILE"
  return ${PIPESTATUS[0]}
}

is_rate_limited_log() {
  grep -qiE 'rate[ _-]?limit|too many requests|usage[ _-]?limit|quota_exceeded|rate_limit_error|insufficient_quota|429 status|model.{0,10}overload' "$LOG_FILE" 2>/dev/null
}

run_claude_attempt "$PRIMARY_MODEL" "[primary]"
RC=$?
if [[ "$RC" -ne 0 ]] && [[ "$PRIMARY_MODEL" != "$FALLBACK_MODEL" ]] && is_rate_limited_log; then
  echo "[$(date +%H:%M:%S)] WARN: primary $PRIMARY_MODEL rate-limited, retrying with $FALLBACK_MODEL" | tee -a "$LOG_FILE"
  run_claude_attempt "$FALLBACK_MODEL" "[fallback]"
  RC=$?
fi

STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo 'FAILED:no-status')"
echo "[$(date +%H:%M:%S)] ci-doctor result: $STATUS  (claude rc=$RC)" | tee -a "$LOG_FILE"

# 結果を GitHub PR comment + label で発信 (conflict-doctor と同パターン)
ensure_label() {
  gh label create "needs-manual-ci-fix" --color "B60205" --description "ci-doctor 自動修復失敗、手動対応が必要" 2>/dev/null || true
}
post_pr_comment() {
  gh pr comment "$PR_NUM" --body "$1" 2>&1 | tee -a "$LOG_FILE" || true
}
add_label() {
  ensure_label
  gh pr edit "$PR_NUM" --add-label "needs-manual-ci-fix" 2>&1 | tee -a "$LOG_FILE" || true
}
remove_label() {
  gh pr edit "$PR_NUM" --remove-label "needs-manual-ci-fix" 2>/dev/null || true
}

case "$STATUS" in
  OK*)
    remove_label
    exit 0
    ;;
  *)
    REASON="${STATUS#FAILED:}"
    LOG_REL="${LOG_FILE#$REPO/}"
    COMMENT="$(cat <<COMMENT
🤖 **ci-doctor: 自動修復失敗** ($(date '+%Y-%m-%d %H:%M:%S %Z'))

- 理由: \`${REASON}\`
- ログ: \`${LOG_REL}\`
- worktree: \`${WORKTREE_DIR}\`
- 使用モデル: \`${PRIMARY_MODEL}\` (rate-limit 時 \`${FALLBACK_MODEL}\` fallback)

**手動修復手順**:

\`\`\`bash
cd ${WORKTREE_DIR}
gh pr checks ${PR_NUM}
gh run view <failed-run-id> --log-failed | tail -50
# fix → commit → push
\`\`\`

cooldown 2 時間後に ci-doctor が自動再試行します。

— [claude-executor/bin/ci-doctor.sh](https://github.com/mister-X-is-your-father/manademia/blob/main/claude-executor/bin/ci-doctor.sh)
COMMENT
)"
    post_pr_comment "$COMMENT"
    add_label
    exit 1
    ;;
esac
