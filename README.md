# claude-executor

> GitHub issue を Claude consumer に直列消化させ、PR 化 → CI green → auto-merge までを自動化する pipeline。
> 「自分は寝てる間に issue が消化されている」状態を作る仕組みの最小セット。

## 全体像

```
┌──────────────────────────────────────────────────────────────────┐
│ Layer 1: 消化 (issue → PR)                                       │
│                                                                  │
│  queue-run.sh --watch                                            │
│    └─ consumer.sh <ISSUE_NUM>                                    │
│        └─ claude (sonnet 4.6 / haiku / opus fallback)            │
│            └─ worktree 作成 → 実装 → verify → push → PR 作成      │
│                                                                  │
│ Layer 2: 自動 merge (PR → main)                                  │
│                                                                  │
│  watcher.sh --watch  (60s polling)                               │
│    ├─ CI green 検出 → gh pr merge --merge --delete-branch         │
│    ├─ CI failure 検出 → ci-doctor.sh spawn (= claude が CI fix)   │
│    └─ CONFLICTING 検出 → conflict-doctor.sh spawn (= 自動解決)    │
└──────────────────────────────────────────────────────────────────┘
```

## ディレクトリ構成

```
claude-executor/
├── bin/                              # 実行可能 scripts (全 11)
│   ├── queue-run.sh                  # 全 issue を優先度順に消化する queue
│   ├── consumer.sh                   # 1 issue を end-to-end (worktree → PR)
│   ├── watcher.sh                    # auto-merge watcher (= merge-when-green)
│   ├── ci-doctor.sh                  # CI fail 自動修復 (Sonnet/Opus fallback)
│   ├── conflict-doctor.sh            # merge conflict 自動解決
│   ├── dashboard.sh                  # 消化状況の snapshot 表示
│   ├── cost-tracker.sh               # model 別累積 cost 集計
│   ├── gc.sh                         # 古い worktree / status file 掃除
│   ├── test-dup-audit.sh             # vitest 重複 test を Haiku で audit (応用例)
│   ├── install-queue-runner.sh       # systemd user service として install
│   └── install-watcher.sh            # 同上
├── systemd/
│   ├── queue-runner.service          # Restart=always + linger 共有
│   └── watcher.service               # 同上
└── docs/
    └── runbook.md                    # 運用 manual
```

## クイックスタート

```bash
# 1. 1 issue を手動消化
bash claude-executor/bin/consumer.sh 217

# 2. 全 issue を継続消化 (= watch mode)
bash claude-executor/bin/queue-run.sh --watch

# 3. systemd user service として常駐化 (= session 切断 / PC 再起動でも復活)
bash claude-executor/bin/install-queue-runner.sh
bash claude-executor/bin/install-watcher.sh
```

## 起動条件

- bash 4+
- python3 (= triage logic で使用)
- git
- gh CLI (= GitHub access、認証済)
- claude CLI (= Anthropic API access)
- (optional) systemd (= 常駐化、Linux user service)

## triage ルール (= 自動 skip 条件)

consumer が処理しない issue:
- `area/legal` label (= 法務 review 必須)
- `priority/low` label (= 後回し)
- `consumer-skip` label (= 手動指定)
- milestone "Long-term (Phase 11+)"
- 既に open PR が存在する (= "Closes #N" 検索)
- 直近 FAILED (= cooldown 24h / rate-limit 1h / timeout 6h)

## 模式: model 分岐

| kind | 判定 | model |
|---|---|---|
| `docs-trivial` | `type/docs` + 低優先 | Haiku |
| `docs-detailed` | `type/docs` + critical/high, or refactor + tech-debt | Sonnet |
| `impl` (default) | type/feature, priority/critical 等 | Sonnet |
| `complex` | (将来用) | Opus |
| `fallback` | rate-limit / overload 検出時 | Opus |

## ステータス

- 2026-05-16: manademia/ から `claude-executor/` ディレクトリに集約 (= Step A、物理切り出し)
- 次: hard-coded path / label / 命名を一般化 (Step B)
- 後: 別 repo として subtree split + OSS publish (Step C、optional)

## 関連 docs

- 運用 manual: [`docs/runbook.md`](./docs/runbook.md)
- 元 design memo: `/home/neo/manademia/docs/sessions/2026-05-16-*.md`

## 安全規則

- main / master への直接 push は禁止 (= worktree feature branch のみ)
- `--no-verify` / `--force` / `--no-gpg-sign` は使わない
- 同 process は global lockfile で 1 体に制限 (= consumer / doctor / progress)
- 失敗時は status file で cooldown (= 無限再試行防止)
