#!/usr/bin/env bash
# claude-executor/bin/conflict-doctor.sh
#
# PR の merge conflict を Claude (Sonnet 4.6 / Opus 4.7 fallback) に解決させる。
# merge-when-green.sh が `mergeable=CONFLICTING` を検出した時に spawn する想定。
#
# Usage:
#   claude-executor/bin/conflict-doctor.sh <PR_NUMBER>
#
# 動作:
#   1. PR の branch / worktree を特定
#   2. lockfile (/tmp/${PROJECT}-conflict-doctor-pr-<N>.lock) で多重起動防止
#   3. 該当 worktree で `git fetch origin main` + `git merge origin/main --no-edit` 試行
#      既に merge 中なら state そのまま続行
#   4. Claude を `--dangerously-skip-permissions --print` で起動
#      prompt で conflict marker 除去 + 両 branch の意図を保つ resolve を指示
#   5. Claude 完了後 `pnpm typecheck` で構文確認 → 通れば `git push`
#   6. status file (/tmp/${PROJECT}-conflict-doctor-pr-<N>.status) に結果記録
#      - OK             解決 + push 成功 (next loop で merge-when-green が pickup)
#      - FAILED:<phase>  自動解決失敗 (user 介入が必要)
#
# 安全規則:
#   - main branch への直接操作は禁止 (worktree 内 feature branch のみ)
#   - --no-verify / --force / --skip-checks 等は使わない
#   - Claude が解決できない (semantic conflict) 場合は素直に FAILED で exit
#   - 同 PR に対し並行 doctor を起動しない (lockfile)

set -uo pipefail

PR_NUM="${1:-}"
if [[ -z "$PR_NUM" || ! "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <PR_NUMBER>" >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${EXECUTOR_PROJECT_NAME:-manademia}"
LOCKFILE="/tmp/${PROJECT}-conflict-doctor-pr-${PR_NUM}.lock"
STATUS_FILE="/tmp/${PROJECT}-conflict-doctor-pr-${PR_NUM}.status"
LOG_DIR="$REPO/logs"
LOG_FILE="$LOG_DIR/conflict-doctor-pr-${PR_NUM}-$(date +%Y%m%d-%H%M%S).log"
TIMEOUT_SEC="${CONFLICT_DOCTOR_TIMEOUT_SEC:-1800}"
PRIMARY_MODEL="${CONFLICT_DOCTOR_MODEL_PRIMARY:-claude-sonnet-4-6}"
FALLBACK_MODEL="${CONFLICT_DOCTOR_MODEL_FALLBACK:-claude-opus-4-7}"

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
    echo "[$(date +%H:%M:%S)] conflict-doctor already running for PR #$PR_NUM (PID=$OLD_PID), exit" | tee -a "$LOG_FILE"
    exit 0
  fi
  echo "[$(date +%H:%M:%S)] stale conflict-doctor lockfile (PID=$OLD_PID dead), removing..." | tee -a "$LOG_FILE"
  rm -f "$LOCKFILE"
fi
echo "$$" > "$LOCKFILE"
trap cleanup EXIT

# PR 情報
PR_INFO="$(gh pr view "$PR_NUM" --json number,title,headRefName,mergeable,mergeStateStatus 2>/dev/null || echo '')"
if [[ -z "$PR_INFO" ]]; then
  echo "FAILED:pr-not-found" > "$STATUS_FILE"
  echo "[$(date +%H:%M:%S)] ERROR: cannot fetch PR #$PR_NUM" | tee -a "$LOG_FILE"
  exit 1
fi
BRANCH="$(echo "$PR_INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("headRefName",""))')"
TITLE="$(echo "$PR_INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("title",""))')"
MERGEABLE="$(echo "$PR_INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mergeable",""))')"

if [[ "$MERGEABLE" != "CONFLICTING" ]]; then
  echo "[$(date +%H:%M:%S)] PR #$PR_NUM mergeable=$MERGEABLE (not CONFLICTING), nothing to do" | tee -a "$LOG_FILE"
  echo "OK:no-conflict" > "$STATUS_FILE"
  exit 0
fi

echo "[$(date +%H:%M:%S)] conflict-doctor starting" | tee -a "$LOG_FILE"
echo "  PR        : #$PR_NUM ($TITLE)" | tee -a "$LOG_FILE"
echo "  branch    : $BRANCH" | tee -a "$LOG_FILE"
echo "  primary   : $PRIMARY_MODEL" | tee -a "$LOG_FILE"
echo "  fallback  : $FALLBACK_MODEL" | tee -a "$LOG_FILE"
echo "  timeout   : ${TIMEOUT_SEC}s" | tee -a "$LOG_FILE"

# worktree path 解決 (`git worktree list` で branch 一致行を抽出)
WORKTREE_DIR="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk -v b="$BRANCH" '
  /^worktree / {wt=$2}
  /^branch / {if ($2 == "refs/heads/" b) print wt}
')"
if [[ -z "$WORKTREE_DIR" || ! -d "$WORKTREE_DIR" ]]; then
  # 既存 worktree なしの場合は ephemeral worktree を auto-create。
  # auto-create された worktree は EXIT 時に cleanup() が remove する。
  # 主目的: consumer 経由で作成された PR (= worktree 残ってない)、PR 著者が
  # 手動 push した PR、別 host で作業した PR 等を、自動で resolve 可能にする。
  echo "[$(date +%H:%M:%S)] no existing worktree for '$BRANCH', creating ephemeral worktree..." | tee -a "$LOG_FILE"
  WORKTREE_DIR="/tmp/${PROJECT}-conflict-doctor-wt-pr-${PR_NUM}"
  if [[ -d "$WORKTREE_DIR" ]]; then
    # 前回 run の残骸を強制掃除
    git -C "$REPO" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
    rm -rf "$WORKTREE_DIR"
  fi
  if ! git -C "$REPO" fetch origin "$BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    echo "FAILED:fetch-branch" > "$STATUS_FILE"
    echo "[$(date +%H:%M:%S)] ERROR: cannot fetch branch '$BRANCH' from origin" | tee -a "$LOG_FILE"
    exit 1
  fi
  # local branch を作って worktree add (-B = force-create / reset)
  if ! git -C "$REPO" worktree add -B "$BRANCH" "$WORKTREE_DIR" "origin/$BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
    echo "FAILED:worktree-create" > "$STATUS_FILE"
    echo "[$(date +%H:%M:%S)] ERROR: cannot create worktree at '$WORKTREE_DIR'" | tee -a "$LOG_FILE"
    exit 1
  fi
  # upstream を設定して push が default で正しい先に向かうように
  git -C "$WORKTREE_DIR" branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
  WORKTREE_CREATED=true
fi
echo "  worktree  : $WORKTREE_DIR (ephemeral=$WORKTREE_CREATED)" | tee -a "$LOG_FILE"

PROMPT_BODY=$(cat <<EOF
あなたは ${PROJECT} リポジトリの merge conflict 自動解決 sub-agent です。
PR #${PR_NUM} (branch: ${BRANCH}) を origin/main に対して merge できる状態に修正してください。

## 作業ディレクトリ
${WORKTREE_DIR} (直接 cd して作業すること、他 worktree / main worktree は触らない)

## 手順

1. \`cd ${WORKTREE_DIR}\` してから \`git status -sb\` で現状確認
2. **既に merge 中** (UU / AA 等の unmerged path がある場合) → そのまま step 4 へ
   **clean な状態** → \`git fetch origin main\` + \`git merge origin/main --no-edit\` で衝突を露出させる
3. \`git status -s\` で conflict ファイル一覧を取得 (UU / AA / DU / UD / DD 行)
4. 各 conflict ファイルを Read で開き、\`<<<<<<< HEAD\` / \`=======\` / \`>>>>>>> origin/main\` マーカーを除去:
   - **両 branch が独立に追加した内容** (additive): 両方を保つ (例: schema.ts に table 定義を片側ずつ append)
   - **同じ箇所を異なる方法で修正** (semantic): 両 branch の意図を統合する (片方を捨てない、user 確認できないので最善努力)
   - **不明瞭で危険** (1 行レベルの相反するロジック書き換え等): /tmp/${PROJECT}-conflict-doctor-pr-${PR_NUM}.status に \`FAILED:unresolvable:<reason>\` を書いて exit
5. \`git add <resolved-files>\` で stage
6. \`pnpm typecheck\` で構文 OK 確認 (失敗したら最大 2 回まで自分で修正試行、それでも fail なら FAILED:typecheck)
7. \`pnpm lint\` でも確認 (warnings は許容、errors のみ fail 扱い)
8. \`git commit\` (default merge commit message で OK、追加で 1 行 \"resolved by conflict-doctor sub-agent\" を本文に)
9. \`git push\` (該当 branch のみ、main は決して push しない)
10. \`/tmp/${PROJECT}-conflict-doctor-pr-${PR_NUM}.status\` に \`OK\` を書いて exit

## 禁止
- conflict marker (<<<, ===, >>>) を残したまま commit
- pnpm typecheck 失敗のまま push
- main / master / production branch への直接操作
- --no-verify / --force / --no-gpg-sign 等の安全機構 bypass
- 他 PR / 他 worktree への touch
- semantic conflict を「適当に」片方だけ残す (両 branch の意図統合が無理ならエスカレーション = FAILED:unresolvable)

## 完了基準
status file に \`OK\` (成功) or \`FAILED:<phase>:<reason>\` (失敗) を 1 行で書いて exit。
途中ハングしないよう、claude プロセスは ${TIMEOUT_SEC} 秒で打ち切られます。
EOF
)

# rm 念のため pre-existing status をリセット
rm -f "$STATUS_FILE"

# Claude invocation (rate-limit 落ち時 fallback model)
run_claude_attempt() {
  local model="$1"
  local label="$2"
  echo "[$(date +%H:%M:%S)] $label invoking claude (model=$model)" | tee -a "$LOG_FILE"
  timeout --signal=TERM --kill-after=30s "${TIMEOUT_SEC}s" \
    claude \
      --model "$model" \
      --dangerously-skip-permissions \
      --print \
      "$PROMPT_BODY" \
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

# status check
STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo 'FAILED:no-status')"
echo "[$(date +%H:%M:%S)] conflict-doctor result: $STATUS  (claude rc=$RC)" | tee -a "$LOG_FILE"

# 結果を **GitHub PR comment + label** で発信する。
# 理由: Claude session の run_in_background tracking は CLI 跨ぎで生存しないので、
# 通知経路として GitHub の email / web 通知 + PR label に乗せる方が頑健。
# user / 別 Claude session が `gh pr list --label needs-manual-merge` で抽出可能。
post_pr_comment() {
  local body="$1"
  gh pr comment "$PR_NUM" --body "$body" 2>&1 | tee -a "$LOG_FILE" || true
}
ensure_label() {
  # label 不存在なら作成 (idempotent)
  gh label create "needs-manual-merge" --color "B60205" --description "conflict-doctor 自動解決失敗、手動対応が必要" 2>/dev/null || true
}
add_label() {
  ensure_label
  gh pr edit "$PR_NUM" --add-label "needs-manual-merge" 2>&1 | tee -a "$LOG_FILE" || true
}
remove_label() {
  gh pr edit "$PR_NUM" --remove-label "needs-manual-merge" 2>/dev/null || true
}

case "$STATUS" in
  OK*)
    # 過去に label 付いてた場合は外す (再試行成功 shock)
    remove_label
    # OK 時の comment は省略 (merge されれば自然に閉じるので冗長)
    exit 0
    ;;
  *)
    REASON="${STATUS#FAILED:}"
    LOG_REL="${LOG_FILE#$REPO/}"
    COMMENT_BODY="$(cat <<COMMENT
🤖 **conflict-doctor: 自動解決失敗** ($(date '+%Y-%m-%d %H:%M:%S %Z'))

- 理由: \`${REASON}\`
- ログ: \`${LOG_REL}\`
- worktree: \`${WORKTREE_DIR}\`
- 使用モデル: \`${PRIMARY_MODEL}\` (rate-limit 時 \`${FALLBACK_MODEL}\` fallback)

**手動解決手順** (新 Claude session でも可):

\`\`\`bash
cd ${WORKTREE_DIR}
git status                     # 衝突ファイル確認
# 各ファイルの conflict marker (<<<, ===, >>>) を解決
git add .
git commit                     # default merge commit message で OK
git push
\`\`\`

cooldown 2 時間後に conflict-doctor が自動再試行します (status file を削除すると即時再試行可)。

— [claude-executor/bin/conflict-doctor.sh](https://github.com/mister-X-is-your-father/manademia/blob/main/claude-executor/bin/conflict-doctor.sh)
COMMENT
)"
    post_pr_comment "$COMMENT_BODY"
    add_label
    exit 1
    ;;
esac
