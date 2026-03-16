# jet_orchestra チュートリアル

BEAM/OTP 上に構築された、Jet 言語向けマルチエージェントオーケストレーションフレームワーク。

## jet_orchestra とは

以下の機能を備えたマルチエージェントシステムを構築するためのフレームワークです:

- ポーリング、プッシュ (直接投入)、またはその両方 (ハイブリッド) でタスクを受信
- WORKFLOW.md (YAML + プロンプトテンプレート) で宣言的に設定
- 各タスクを隔離ワークスペースで AI エージェントワーカーに振り分け
- マルチターン実行、指数バックオフリトライ、停滞検知
- PR レビューコメントを検知し、レビュー指摘への対応を自動実行
- ワーカークラッシュ (OTP 監視)、マシン再起動 (チェックポイント永続化) からの復旧
- 各ステージでライフサイクルフック (セットアップ、クリーンアップ、CI) を実行

## アーキテクチャ概要

```
                                WORKFLOW.md
                               (YAML + テンプレート)
                                     |
                                     v
                                Config::from_workflow()
                                     |
  プッシュ (Webhook / MQ)  ポーリング  v         Store (FileStore)
         |                |     +---------+          |
         v                v     | Config  |          v
  +------+----------------+----+---------+----+----------+
  |                    Scheduler (アクター)                |
  |  submit / reconcile -> claim -> dispatch -> monitor   |
  |       ^                           |            |      |
  |       | :tick / :review_tick      | spawn      |      |
  |       +---------------------------+            |      |
  |                                    v           |      |
  |                            Worker (アクター) <--+      |
  |                            Workspace + Hooks          |
  |                            Runner (Claude, ...)       |
  |                            turn 1 -> N                |
  |                                    |                  |
  |                            {:worker_done}             |
  |                                    v                  |
  |                            リトライ / 完了             |
  |                                    |                  |
  |                            review_pending             |
  |                                    ^                  |
  |                   GitHubPRReviewSource                 |
  +-------------------------------------------------------+
```

### モジュール構成

```
src/jet_orchestra/
├── Scheduler.jet       # タスクスケジューラ (オーケストレーター本体)
├── Worker.jet          # マルチターンワーカー (レビュー時のワークスペース再利用)
├── Config.jet          # 設定、フック、ワークフロー読み込み
├── Workflow.jet        # WORKFLOW.md パーサー + {{テンプレート}} レンダラー
├── WorkflowRouter.jet  # マルチワークフロールーティング (ラベルベース)
├── Runner.jet          # エージェントランナープロトコル
├── TaskSource.jet      # タスクソースプロトコル
├── Store.jet           # 永続化プロトコル
├── FileStore.jet       # JSON チェックポイント永続化
├── DetsStore.jet       # DETS 個別タスク永続化
├── Workspace.jet       # 隔離ディレクトリ管理
├── Hooks.jet           # ライフサイクルフック実行
├── Backoff.jet         # リトライ戦略
├── Log.jet             # 構造化ログ
└── PythonBridge.jet    # BEAM <-> Python 連携

src/jet_orchestra_runners/
├── ClaudeSimpleRunner.jet  # claude --print (os::cmd)
├── ClaudeCodeRunner.jet    # claude --print (port)
├── ClaudeAgentRunner.jet   # Claude Agent SDK (Python)
└── CodexRunner.jet         # Codex JSON-RPC

src/jet_orchestra_sources/
├── GitHubTaskSource.jet       # GitHub Issues (gh CLI)
├── GitHubPRReviewSource.jet   # PR レビューコメント監視
└── LinearTaskSource.jet       # Linear API (GraphQL)
```

## クイックスタート

### 最も簡単な方法: WORKFLOW.md

`WORKFLOW.md` ファイルを作成:

```yaml
---
max_turns: 5
max_concurrent: 3
workspace_root: /tmp/orchestra

hooks:
  after_create: "git clone https://github.com/$ORCHESTRA_GITHUB_REPO . && git checkout -b orchestra-$ORCHESTRA_TASK_ID"
  before_run: "git pull origin main --no-edit 2>/dev/null; true"
  after_run: "git add -A && git commit -m 'fix' && git push -u origin HEAD && gh pr create --fill 2>/dev/null; true"
  before_review_run: "git fetch origin && git pull --no-edit 2>/dev/null; true"
  after_review_run: "git add -A && git commit -m '[orchestra] address review' && git push; true"

review:
  max_rounds: 5

allowed_tools: "Read Edit Write Bash(python:*) Bash(pytest:*)"
---
あなたはソフトウェアエンジニアです。以下の Issue を修正してください:
タイトル: {{task.title}}
内容: {{task.description}}
試行回数: {{attempt}}
```

使い方:

```jet
module MyOrchestra
  def self.run()
    config = Config::from_workflow("WORKFLOW.md")
    orch = Scheduler::Instance.spawn(config, :GitHubTaskSource, :ClaudeSimpleRunner, {
      store: :FileStore,
      review_source: :GitHubPRReviewSource
    })
    # Scheduler が Issue をポーリング、Claude が修正、PR 作成、レビュー対応を自動実行
  end
end
```

```sh
ORCHESTRA_GITHUB_REPO=myorg/myrepo ./jet -r MyOrchestra::run MyOrchestra.jet
```

### コードで設定

WORKFLOW.md の内容はすべてコードでも設定できます:

```jet
config = Config::new({
  mode: :hybrid,
  max_concurrent: 3,
  max_turns: 5,
  workspace_root: "/tmp/orchestra",
  after_create_hook: "git clone ... .",
  before_run_hook: "npm install",
  after_run_hook: "git push && gh pr create --fill",
  before_review_run_hook: "git fetch && git pull",
  after_review_run_hook: "git add -A && git commit -m '[orchestra] review' && git push",
  max_review_rounds: 5,
  allowed_tools: "Read Edit Write Bash(python:*)"
})
```

`opts` のフックは Config のフックを上書きします:

```jet
# Config がベースのフックを提供、opts で特定のフックを上書き
orch = Scheduler::Instance.spawn(config, source, runner, {
  hooks: {after_run: "カスタム上書き"}  # config.after_run_hook を上書き
})
```

### プッシュモード

```jet
config = Config::new({mode: :push, max_concurrent: 3})
orch = Scheduler::Instance.spawn(config, nil, nil, {})
orch.submit({id: "1", title: "バグ修正", description: "..."})
```

### マルチワークフロールーティング

タスクの種類 (bug, feature, レビュー対応) に応じて異なるワークフローを使い分けられます。Scheduler がタスクのラベルに基づいて自動選択します。3段階フォールバック:

1. **`workflow_router`** (モジュール) — 最大の柔軟性。`Module::select(task) -> path` を実装。
2. **`workflows`** (マップ) — ラベル → パスの対応表。
3. **`workflow_dir`** (ディレクトリ) — ラベルとファイル名を自動マッチ。
4. (なし) — 単一ワークフロー動作 (後方互換)。

ワークフロールーティングはタスクソースに依存しません。GitHub、Linear、プッシュモード、あるいは独自ソースのいずれでも動作します。必要なのはタスクに `labels` フィールド (文字列のリスト) があることだけです。`GitHubTaskSource` と `LinearTaskSource` は自動的にラベルを付与します。プッシュモードでは submit 時にラベルを指定してください。

#### ディレクトリ方式 (最も簡単)

```jet
# workflows/bug.md, workflows/feature.md, workflows/default.md を用意
config = Config::new({workflow_dir: "workflows/"})

# どのタスクソースでも動作:
orch = Scheduler::Instance.spawn(config, :GitHubTaskSource, :ClaudeSimpleRunner, {})
orch = Scheduler::Instance.spawn(config, :LinearTaskSource, :ClaudeSimpleRunner, {})

# プッシュモードでも使える — submit 時にラベルを付けるだけ:
orch = Scheduler::Instance.spawn(config, nil, :ClaudeSimpleRunner, {})
orch.submit({id: "1", title: "クラッシュ修正", labels: ["bug"]})
orch.submit({id: "2", title: "ダークモード追加", labels: ["feature"]})

# labels: ["bug"] のタスク -> workflows/bug.md
# labels: ["feature"] のタスク -> workflows/feature.md
# 不明なラベル -> workflows/default.md
```

#### マップ方式

```jet
config = Config::new({workflows: {
  bug: "wf/bug.md",
  feature: "wf/feat.md",
  default: "wf/default.md"
}})
```

#### ルーターモジュール方式 (最大柔軟性)

```jet
module MyRouter
  def self.select(task)
    labels = maps::get(:labels, task, [])
    if lists::member("urgent", labels)
      "workflows/urgent.md"
    elsif lists::member("bug", labels)
      "workflows/bug.md"
    else
      "workflows/default.md"
    end
  end
end

config = Config::new({workflow_router: :MyRouter})
```

各ワークフローファイルは通常の WORKFLOW.md 形式 (YAML フロントマター + プロンプトテンプレート)。選択されたワークフローの設定がベース設定を上書きします (YAML に明示された値のみ)。

ワークフローファイルはパスと mtime でキャッシュされ、ファイル変更時は次のタスクで自動的に再読み込みされます。

## 設定リファレンス

### Config フィールド

| フィールド | デフォルト | 説明 |
|---|---|---|
| `mode` | `:poll` | `:poll`, `:push`, `:hybrid` |
| `poll_interval_ms` | 30000 | タスクポーリング間隔 |
| `max_concurrent` | 5 | 最大並行ワーカー数 |
| `max_turns` | 10 | タスクあたりの最大ターン数 |
| `max_retries` | 3 | 失敗時の最大リトライ回数 |
| `max_retry_backoff_ms` | 300000 | バックオフ上限 |
| `stall_timeout_ms` | 300000 | 停滞検知タイムアウト |
| `workspace_root` | `/tmp/orchestra` | ワークスペースベースディレクトリ |
| `hook_timeout_ms` | 60000 | フック実行タイムアウト |
| `max_review_rounds` | 5 | PR レビューの最大ラウンド数 |
| `review_poll_interval_ms` | 60000 | レビューコメントのポーリング間隔 |
| `allowed_tools` | `Read Edit Write Bash(python:*) Bash(pytest:*) Bash(git:*)` | Claude CLI の許可ツール |
| `after_create_hook` | nil | ワークスペース作成後のシェルコマンド |
| `before_run_hook` | nil | 各エージェントターン前のシェルコマンド |
| `after_run_hook` | nil | エージェント完了後のシェルコマンド |
| `before_remove_hook` | nil | ワークスペース削除前のシェルコマンド |
| `before_review_run_hook` | nil | レビューターン前のシェルコマンド |
| `after_review_run_hook` | nil | レビューターン後のシェルコマンド |
| `workflow_path` | nil | WORKFLOW.md のパス (`from_workflow` で設定) |
| `prompt_template` | nil | プロンプトテンプレート文字列 (`from_workflow` で設定) |
| `workflow_dir` | nil | ラベルベースルーティング用ワークフローディレクトリ |
| `workflow_router` | nil | `select(task) -> path` を実装するモジュール |
| `workflows` | nil | `ラベル -> ワークフローパス` のマップ |

### WORKFLOW.md フォーマット

```yaml
---
# フラットキー
max_turns: 5
max_concurrent: 3
poll_interval_ms: 30000
workspace_root: /tmp/orchestra
mode: hybrid
allowed_tools: "Read Edit Write"

# ネストキー
hooks:
  after_create: "..."
  before_run: "..."
  after_run: "..."
  before_remove: "..."
  before_review_run: "..."
  after_review_run: "..."
  timeout_ms: 60000

review:
  max_rounds: 5
  poll_interval_ms: 60000
---
{{task.title}}, {{task.description}}, {{attempt}} 変数が使えるプロンプトテンプレート
```

### フック

```
ワークスペース作成 --> after_create --> before_run --+
                                                      |
                                       [エージェント] <-+ (マルチターン)
                                                      |
                                       after_run -----+
                                          |
                                     (レビュー時)
                                          |
                                before_review_run --+
                                                    |
                                 [レビュー対応]    <-+
                                                    |
                                after_review_run ---+
                                          |
                                     before_remove --> ワークスペース削除
```

レビュータスクでは `before_review_run`/`after_review_run` が定義されていればそちらが使われ、なければ `before_run`/`after_run` にフォールバック。

環境変数: `$ORCHESTRA_TASK_ID`, `$ORCHESTRA_TASK_TITLE`

## プロトコル一覧

| プロトコル | 関数 | 組み込み |
|---|---|---|
| **Runner** | `run/4`, `stop/1` | `Runner`, `ClaudeSimpleRunner`, `ClaudeCodeRunner`, `ClaudeAgentRunner`, `CodexRunner` |
| **TaskSource** | `fetch_tasks/1`, `update_task/3`, `fetch_task_state/2` | `TaskSource`, `GitHubTaskSource`, `LinearTaskSource` |
| **Store** | `save/2`, `load/1`, `delete/1`, `save_task/3`*, `load_task/2`*, `delete_task/2`*, `list_task_ids/1`* | `Store`, `FileStore`, `DetsStore` |
| **ReviewSource** | `fetch_tasks/1` | `GitHubPRReviewSource` |

### GitHub 認証

```sh
gh auth login        # 対話式
gh auth status       # 確認
```

```jet
GitHubTaskSource::check_auth()  # => :ok | {:error, msg}
```

## PR レビューループ

`review_source: :GitHubPRReviewSource` を設定すると:

```
Issue open --> エージェント修正 --> PR 作成 --> review_pending
    --> レビュアーがコメント投稿
    --> GitHubPRReviewSource が新コメントを検知
    --> レビュー子タスク "ID-review-N" を投入
    --> Worker がワークスペースを再利用、Claude がフィードバックに対応
    --> after_review_run フックが修正をプッシュ
    --> APPROVED または max_review_rounds まで繰り返し
```

`[orchestra]` を含むコメントは自己ループ防止のためフィルタされます。

## 永続化

### FileStore (JSON 一括チェックポイント)

```jet
orch = Scheduler::Instance.spawn(config, source, runner, {store: :FileStore})
# チェックポイント: <workspace_root>/.orchestra/checkpoint.json
# 永続化: claimed, retry_attempts, done, completed, review_pending
```

同じ config + store で再起動すると、タスク状態が自動復元されます。

### DetsStore (DETS 個別タスク永続化)

```jet
orch = Scheduler::Instance.spawn(config, source, runner, {store: :DetsStore})
# DETS ファイル: <workspace_root>/.orchestra/state.dets
# 個別タスク更新: 変更されたタスクのみ書き込み、全状態の書き直し不要
```

DetsStore の FileStore に対する利点:
- **JSON シリアライズ不要** — Erlang のネイティブ term をそのまま保存
- **個別タスク更新** — 1 タスク完了時にそのタスクのレコードだけを書き込み (全状態ではない)
- 同一 BEAM ノード内の**並行アクセス安全**

Scheduler は `supports_per_task?()` を自動検出し、対応する Store では個別タスク永続化を使用します。互換性のためバルク API (`save/load/delete`) もサポートされています。

個別タスク API (* = オプション、`supports_per_task?() == true` の Store のみ):

| 関数 | 説明 |
|---|---|
| `save_task(root, id, data)` | 単一タスクレコードの保存 |
| `load_task(root, id)` | 単一タスクレコードの読み込み |
| `delete_task(root, id)` | 単一タスクレコードの削除 |
| `list_task_ids(root)` | 保存済みタスク ID の一覧 |
| `save_meta(root, data)` | メタデータ (claimed 順序) の保存 |
| `save_review(root, id, data)` | レビュー追跡データの保存 |

## コンパイルとテスト

```sh
gleam build && gleam export erlang-shipment && escript build_escript.erl
for f in src/jet_orchestra/*.jet; do ./jet "$f"; done
for f in src/jet_orchestra_runners/*.jet src/jet_orchestra_sources/*.jet; do ./jet "$f"; done
gleam test  # 51 テスト

# Jet ランタイムテスト
./jet -r TestBackoff::run examples/orchestra/TestBackoff.jet
./jet -r TestConfig::run examples/orchestra/TestConfig.jet
./jet -r TestLog::run examples/orchestra/TestLog.jet
./jet -r TestWorkspace::run examples/orchestra/TestWorkspace.jet
./jet -r TestRunner::run examples/orchestra/TestRunner.jet
./jet examples/orchestra/MockTaskSource.jet
./jet -r TestScheduler::run examples/orchestra/TestScheduler.jet
./jet -r TestPushMode::run examples/orchestra/TestPushMode.jet
./jet -r TestPersistence::run examples/orchestra/TestPersistence.jet
./jet -r TestDetsStore::run examples/orchestra/TestDetsStore.jet
./jet -r TestWorkflowRouter::run examples/orchestra/TestWorkflowRouter.jet
./jet -r WorkflowDemo::run examples/orchestra/WorkflowDemo.jet
```
