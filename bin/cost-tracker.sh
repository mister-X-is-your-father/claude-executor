#!/usr/bin/env bash
# claude-executor/bin/cost-tracker.sh
#
# logs/consumer-stats.jsonl から model 別の累積 cost を推定して表示。
# 実コストは Anthropic billing dashboard で確認、本 script は近似値 (= elapsed_sec
# から token 数を推定するヒューリスティック)。
#
# Usage:
#   claude-executor/bin/cost-tracker.sh                # 全期間の集計
#   claude-executor/bin/cost-tracker.sh --since 1d     # 直近 1 日
#   claude-executor/bin/cost-tracker.sh --since 7d     # 直近 7 日
#
# 関連: runbooks/issue-consumer.md, #336 (Anthropic API spend monitoring)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${EXECUTOR_PROJECT_NAME:-manademia}"
STATS_FILE="$REPO/logs/consumer-stats.jsonl"

SINCE=""
[[ "${1:-}" == "--since" ]] && SINCE="${2:-}"

if [[ ! -f "$STATS_FILE" ]]; then
  echo "no stats file at $STATS_FILE"
  exit 0
fi

python3 <<PY
import json
import sys
import time
from datetime import datetime, timedelta, timezone

STATS = "$STATS_FILE"
SINCE = "$SINCE"

# モデル別 単価 (USD per 1M tokens、2026 年現在 Anthropic 公開価格)
MODEL_PRICING = {
    "claude-haiku-4-5-20251001":   {"in": 0.80,  "out": 4.00},
    "claude-sonnet-4-6":           {"in": 3.00,  "out": 15.00},
    "claude-opus-4-7":             {"in": 15.00, "out": 75.00},
    "claude-opus-4-7[1m]":         {"in": 30.00, "out": 150.00},  # extended context 額
}

# elapsed_sec → token 数の hueristic
# Claude --print は約 80 tok/sec output、その上 input は 5-10x のスケール
# (= 大半 prompt 内容、生成は少なめ)
def estimate_tokens(elapsed_sec):
    # 平均: 1 sec ≈ 80 output tokens、input は ~3x output
    output_tokens = elapsed_sec * 80
    input_tokens  = output_tokens * 3
    return input_tokens, output_tokens

def estimate_cost(model, elapsed_sec):
    p = MODEL_PRICING.get(model)
    if not p:
        return None
    inp, out = estimate_tokens(elapsed_sec)
    cost = (inp / 1_000_000) * p["in"] + (out / 1_000_000) * p["out"]
    return cost

# since filter
cutoff = None
if SINCE:
    val = SINCE.rstrip("d").rstrip("h")
    unit = SINCE[-1]
    n = int(val)
    delta = timedelta(days=n) if unit == "d" else timedelta(hours=n)
    cutoff = datetime.now(timezone.utc) - delta

totals = {}  # model -> (count, total_elapsed, total_cost, ok_count, fail_count)
fail_count = 0
total_runs = 0

with open(STATS) as f:
    for line in f:
        try:
            r = json.loads(line)
        except Exception:
            continue
        if cutoff:
            try:
                ts = datetime.fromisoformat(r["ts"].replace("Z", "+00:00"))
                if ts < cutoff:
                    continue
            except Exception:
                continue

        model = r.get("model", "unknown")
        elapsed = r.get("elapsed_sec", 0) or 0
        status = r.get("status", "")
        is_ok = status.startswith("OK")
        cost = estimate_cost(model, elapsed) or 0

        m = totals.setdefault(model, {"count": 0, "elapsed": 0, "cost": 0.0, "ok": 0, "fail": 0})
        m["count"] += 1
        m["elapsed"] += elapsed
        m["cost"] += cost
        if is_ok:
            m["ok"] += 1
        else:
            m["fail"] += 1
        total_runs += 1
        if not is_ok:
            fail_count += 1

if not totals:
    print("no runs in the specified window")
    sys.exit(0)

print(f"{'='*70}")
period = SINCE if SINCE else "all-time"
print(f" Consumer Cost Estimate (period: {period}, runs: {total_runs})")
print(f"{'='*70}")
print()
print(f"  {'model':<35} {'runs':>5} {'avg_sec':>8} {'cost(USD)':>10}")
print(f"  {'-'*35} {'-'*5} {'-'*8} {'-'*10}")

grand_total_cost = 0
grand_total_elapsed = 0
for model, m in sorted(totals.items(), key=lambda x: -x[1]["cost"]):
    avg = m["elapsed"] / m["count"] if m["count"] else 0
    print(f"  {model:<35} {m['count']:>5} {avg:>8.0f} {m['cost']:>10.4f}")
    grand_total_cost += m["cost"]
    grand_total_elapsed += m["elapsed"]
print(f"  {'-'*35} {'-'*5} {'-'*8} {'-'*10}")
avg_all = grand_total_elapsed / total_runs if total_runs else 0
print(f"  {'TOTAL':<35} {total_runs:>5} {avg_all:>8.0f} {grand_total_cost:>10.4f}")
print()
print(f"  success: {sum(m['ok'] for m in totals.values())} / {total_runs}")
print(f"  failed:  {fail_count} / {total_runs}")
print()
print("注意: 上記 cost は elapsed_sec から推定した近似値。実額は Anthropic billing")
print("dashboard で確認 (https://console.anthropic.com/settings/usage)")

# 200 issue full burndown 想定
remaining = 180  # ざっくり
if grand_total_cost > 0 and total_runs > 0:
    avg_cost_per_run = grand_total_cost / total_runs
    projected = avg_cost_per_run * remaining
    print()
    print(f"  Projected (残 {remaining} 件 × avg \${avg_cost_per_run:.4f}/run): ~\${projected:.2f}")
PY
