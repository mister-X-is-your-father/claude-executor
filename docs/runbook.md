# Issue Consumer 運用 Runbook

> 状態: in_progress (2026-05-15 起稿)
> 関連: PR #438 (実装)、PR #439 (PoC)

GitHub issue 200 件規模を Sonnet/Haiku/Opus で順次自動消化する仕組みの運用マニュアル。
ci-doctor.sh と同じ pattern (lockfile / status / cooldown / model fallback)。

---

## 構成

| File | 役割 |
|---|---|
| `claude-executor/bin/consumer.sh` | 1 issue → 1 sub-agent 起動 (worktree → 実装 → verify → PR) |
| `claude-executor/bin/queue-run.sh` | 未消化 issue を priority + milestone 順で 1 件ずつ consumer に渡す orchestrator |
| `claude-executor/bin/dashboard.sh` | 稼働状況 + 累積 stats のスナップショット表示 |
| `logs/consumer-stats.jsonl` | per-run JSON log (= issue / kind / model / elapsed / status) |
| `logs/issue-consumer-<N>-*.log` | 個別 run の Claude --print 出力 |
| `logs/issue-queue-watch.log` | queue orchestrator の進行 log |

---

## 起動 / 停止

### 1 件だけ実行 (PoC、特定 issue)

```bash
bash claude-executor/bin/consumer.sh 315
# → /tmp/manademia-issue-consumer-315.status に OK:PR#<N> or FAILED:<reason>
```

### Queue mode (= 連続消化)

```bash
# milestone "MVP 本番リリース" を上から消化 (max 5 件)
bash claude-executor/bin/queue-run.sh --milestone "MVP 本番リリース" --max 5

# watch mode (= eligible が無くなるまで延々消化)
nohup bash claude-executor/bin/queue-run.sh --watch \
  --milestone "MVP 本番リリース" \
  > logs/issue-queue-watch.log 2>&1 &
```

### 停止

```bash
# queue orchestrator を kill
pkill -f issue-queue-run.sh

# 既走行中の consumer は完了まで待つ (= timeout 2400s で自動切断、強制 kill は worktree leak の元)
```

---

## 状態確認

```bash
# スナップショット
bash claude-executor/bin/dashboard.sh

# 30s ごと更新表示
bash claude-executor/bin/dashboard.sh --watch
```

表示内容:
- 稼働状態 (lockfile + PID)
- queue orchestrator 稼働状態
- 累積 stats (total / OK / SKIP / FAIL / quality-gate)
- 直近 5 件の結果
- open PR 数 / 本 session merged 数
- 残 eligible 件数
- queue runner 直近 log

---

## Triage 規則 (= consumer が skip する条件)

| 条件 | skip 理由 | 復旧 |
|---|---|---|
| label `area/legal` | 法務 review 要、Claude 単独で完結不可 | 法務担当に escalate |
| milestone `Long-term (Phase 11+)` | 将来 phase、現在 scope 外 | milestone 変更 |
| label `priority/low` | 後回し、対応コスト見合わない | priority 上げる |
| label `consumer-skip` | 手動指定 skip | label 外す |
| open PR with `Closes #N` 存在 | 既に in-flight | PR merge 待ち |
| 直近 24h 内 FAILED status | cooldown | status file 削除 or 24h 待つ |

---

## Quality Gate (= rule-based verify)

consumer が PR 作成後、自動 check:

| Gate | 条件 | Fail 時 |
|---|---|---|
| diff size cap | PR additions + deletions ≤ 1500 行 | label `needs-manual-review` + comment |
| Closes link | PR body に `Closes #<N>` あり | label + comment |

quality gate fail = PR は残るが auto-merge されない、手動 review 必須。

---

## Model 分岐

| Kind | Model | Cost (input/output per 1M) | 用途 |
|---|---|---|---|
| `docs-trivial` | claude-haiku-4-5 | $0.80 / $4 | label が `type/docs` かつ priority/medium 以下 |
| `docs-detailed` | claude-sonnet-4-6 | $3 / $15 | priority/high|critical な docs / refactor docs |
| `impl` | claude-sonnet-4-6 | $3 / $15 | feature / improvement 系 (default) |
| `complex` | claude-opus-4-7 | $15 / $75 | spec / 多 file refactor (= 自動分類なし、手動 label `consumer-model-opus` で指示) |

rate-limit 時 fallback: primary → Opus 4.7 (最終手段、最高コスト)。

env override:
```bash
ISSUE_CONSUMER_MODEL_TRIVIAL=...
ISSUE_CONSUMER_MODEL_DETAILED=...
ISSUE_CONSUMER_MODEL_IMPL=...
ISSUE_CONSUMER_MODEL_FALLBACK=...
ISSUE_CONSUMER_TIMEOUT_SEC=2400  # 40 min
```

---

## Cost 予測 (= 200 issue full burndown)

|  | Sonnet 全消化 | Mix (Haiku/Sonnet/Opus 適切配分) |
|---|---|---|
| Input cost | 200 × 4K × $3/M ≈ $2.4 | 200 × 4K × $1.5/M (avg) ≈ $1.2 |
| Output cost | 200 × 2.5K × $15/M ≈ $7.5 | 200 × 2.5K × $8/M (avg) ≈ $4 |
| Total | **~$10** | **~$5** |

prompt caching (claude --print 内部で有効) で実コストは 20-50% 減見込み。
**1 issue あたり ~$0.025-0.05、200 件で $5-10 範囲**。

---

## トラブルシューティング

### Consumer が動かない (即終了)

- `/tmp/manademia-issue-consumer.lock` が stale → 削除
- `/tmp/manademia-issue-consumer-<N>.status` が FAILED で 24h cooldown 中 → 削除 or 24h 待つ
- gh CLI auth 切れ → `gh auth status` 確認

### Worktree leak (= 失敗時に残った)

```bash
# 全 issue worktree を 一括 cleanup
git worktree list | grep "/tmp/manademia-issue-" | awk '{print $1}' | xargs -I{} git worktree remove --force {}
rm -rf /tmp/manademia-issue-*
```

### Queue が空 (= 全 skip)

- triage 規則を見直す (label / milestone)
- in-flight な PR が大量 → 一旦 watcher に merge させてから再開
- `--issue <N>` で特定 issue を強制実行

### Claude --print rate limit

`logs/issue-consumer-<N>-*.log` に "rate_limit" 確認できれば Opus fallback 試行済。
それでも不足なら `ISSUE_CONSUMER_TIMEOUT_SEC=3600` で再試行。

### Quality gate False Positive

- diff 1500 行制限が厳しすぎる → consumer.sh の `1500` を調整
- 大規模 issue は手動 `consumer-skip` label で除外、または `complex` model 指定

---

## 改善案 (= 次世代)

- **Phase 2**: 直接 Anthropic SDK 呼び出しで prompt caching 明示制御 (現在は --print 任せ)
- **Phase 3**: cost monitoring (`gh dashboard --cost` 内製、Anthropic billing API 連動)
- **Phase 4**: PR auto-review (= Sonnet 結果を Opus が再 review、品質 2 段化)
- **Phase 5**: 学習: failed pattern を memory に蓄積、再発 prompt に注入

---

## 関連

- ci-doctor.sh (= pattern 元、CI fix 用)
- conflict-doctor.sh (= 同 pattern、conflict 解決)
- merge-when-green.sh (= auto-merge watcher、consumer の output PR を回収)
- `docs/playbooks/parallel-dev-with-claude-code.md`

---

## v2 改善 (2026-05-15 追加)

### 修正

- ✅ telemetry `elapsed_sec` の計算 (= 起動時 `START_TS` を保持して差分)
- ✅ cooldown を failure 種別で長さ変更 (rate-limit 1h / timeout 6h / other 24h)
- ✅ quality gate v2: 危険 file (migrations / .env / etc) touch 警告 + 空 PR / 短 body 検出

### 新規 script

- `claude-executor/bin/cost-tracker.sh` — `consumer-stats.jsonl` から model 別累積 cost を近似集計、`--since 1d / 7d` で期間絞り込み可
- `claude-executor/bin/gc.sh` — 古い worktree (`/tmp/manademia-issue-*`) と status file を cleanup、cron 推奨

### Cron 推奨設定

```
# crontab -e
0 * * * * bash /home/neo/manademia/claude-executor/bin/gc.sh
0 9 * * * bash /home/neo/manademia/claude-executor/bin/cost-tracker.sh --since 1d
```
