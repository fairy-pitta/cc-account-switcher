# Claude Code マルチアカウント切り替えツール

[![CI](https://github.com/fairy-pitta/cc-account-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/fairy-pitta/cc-account-switcher/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/fairy-pitta/cc-account-switcher?style=flat&color=blue)](https://github.com/fairy-pitta/cc-account-switcher/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-brightgreen)](https://github.com/fairy-pitta/cc-account-switcher)
[![Shell](https://img.shields.io/badge/shell-bash%203.2%2B-89e051)](https://github.com/fairy-pitta/cc-account-switcher)
[![Tests](https://img.shields.io/badge/tests-85%20passing-success)](https://github.com/fairy-pitta/cc-account-switcher/actions)

> [ming86/cc-account-switcher](https://github.com/ming86/cc-account-switcher) からのフォークです。オリジナルの開発者に感謝します！

macOS・Linux・WSL で複数の Claude Code アカウントを簡単に管理・切り替えできるツールです。

**[English version](README.md)**

## デモ

![demo](assets/demo.gif)

## 特徴

- **マルチアカウント管理** — アカウントの追加・削除・一覧表示
- **素早い切り替え** — ローテーション切り替え、番号・メール・プロフィール名で指定切り替え
- **名前付きプロフィール** — `work` や `personal` など分かりやすい名前を付けられる
- **ディレクトリ連動** — ディレクトリごとにアカウントを紐づけ、`cd` 時に自動切り替え
- **ドライラン** — 実際に切り替えずに動作をプレビュー
- **ロールバック** — 切り替え途中で失敗した場合は自動でロールバック
- **レート制限自動切り替え** — 使用量が上限に達したら自動的にアカウントを切り替え（Claude Code フック連携）
- **カスタムエンドポイント** — `ANTHROPIC_BASE_URL` と API キー／トークン型プロバイダー（OpenRouter・ゲートウェイ・プロキシ・セルフホスト）を `ccs add-endpoint` で切り替え可能なアカウントとして追加
- **会話の引き継ぎ** — `--resume` で、切り替え後も現在の会話をそのまま継続。fork するか同一セッションのまま続けるかを選択可能（`ccs resume-mode`）
- **並列分離** — 指定アカウントを専用の `CLAUDE_CONFIG_DIR` で実行（`ccs exec` / `config-dir`、Linux/WSL）
- **診断機能** — ヘルスチェック、ステータス確認、アカウントごとの使用統計
- **クロスプラットフォーム** — macOS・Linux・WSL に対応
- **安全なストレージ** — macOS ではシステムキーチェーン、Linux/WSL では保護されたファイルを使用
- **設定の保持** — 認証情報のみを切り替え。テーマ・設定・プリファレンスはそのまま

## インストール

![install](assets/install.gif)

### curl（最速）

```bash
curl -fsSL https://raw.githubusercontent.com/fairy-pitta/cc-account-switcher/main/ccswitch.sh -o /usr/local/bin/ccs
chmod +x /usr/local/bin/ccs
```

### Homebrew（macOS）

```bash
brew install fairy-pitta/tap/ccswitch
```

### npm / npx

```bash
# グローバルインストール
npm install -g @fairy-pitta/cc-account-switcher

# インストールせずに実行
npx @fairy-pitta/cc-account-switcher --help
```

### Make

```bash
git clone https://github.com/fairy-pitta/cc-account-switcher.git
cd cc-account-switcher
sudo make install
```

### 手動インストール

[最新リリース](https://github.com/fairy-pitta/cc-account-switcher/releases)から `ccswitch.sh` をダウンロードし、`$PATH` の通った場所に `ccs` として配置してください。

## クイックスタート

![quickstart](assets/quickstart.gif)

1. Claude Code に最初のアカウントでログイン
2. `ccs add` — 現在の認証情報を保存
3. ログアウトし、2つ目のアカウントでログイン
4. `ccs add` — 2つ目の認証情報を保存
5. `ccs sw` — アカウントを切り替え
6. 切り替え後は Claude Code を再起動

> **切り替わるもの:** 認証情報のみ。テーマ・設定・プリファレンス・チャット履歴は変更されません。

## 使い方

### アカウント管理

```bash
ccs add                          # 現在のアカウントを追加
ccs ls                           # 管理中のアカウント一覧
ccs rm 2                         # 番号でアカウントを削除
ccs rm user@example.com          # メールアドレスでアカウントを削除
```

### 切り替え

```bash
ccs sw                           # 次のアカウントにローテーション
ccs to 2                         # アカウント #2 に切り替え
ccs to user@example.com          # メールアドレスで切り替え
ccs to work                      # プロフィール名で切り替え
ccs -n sw                        # ドライラン：変更内容をプレビュー
ccs sw -r                        # 切り替えて Claude Code を再起動
ccs sw --no-restart              # 再起動プロンプトなしで切り替え
ccs to 2 --resume                # アカウント 2 に切り替えて会話を再開
ccs to 2 --resume --no-fork-session   # fork せずに再開（セッション ID を維持）
```

#### 切り替え後に会話を再開する

`ccs sw` / `ccs to` は通常、新しい Claude Code セッションを起動し直します。`--resume`
を付けると、いま開いている会話を切り替え後に引き継げます：

```bash
ccs to 2 --resume
```

カレントディレクトリの直近セッションを捕捉して再開するため、新しいアカウントで同じ会話
を継続できます。そのディレクトリに会話履歴がなければ、新規セッションで起動します。

**fork するか、同一セッションのままか。** 会話への戻り方は 2 通りあり、`--resume` は
どちらにも対応します：

| モード | 起動コマンド | 用途 |
|--------|--------------|------|
| `fork`（デフォルト） | `claude --resume <id> --fork-session` | 切り替え先アカウントが所有する、独立したクリーンなセッションが欲しいとき。fork では**新しいセッション ID** が発行されます。 |
| `same` | `claude --resume <id>` | セッション ID を維持したいとき。トランスクリプト監視ツールやオーケストレーターなど、セッション ID を追跡する仕組みが同じ作業履歴を追い続けられます。 |

切り替えごとに指定するか、デフォルトを設定します：

```bash
ccs to 2 --resume --fork-session      # この切り替えでは fork する
ccs to 2 --resume --no-fork-session   # この切り替えでは同一セッションで再開

ccs resume-mode                       # 現在のデフォルトを表示
ccs resume-mode same                  # 以後は同一セッションをデフォルトに
ccs resume-mode fork                  # fork（出荷時のデフォルト）に戻す
```

デフォルトは `~/.claude-switch-backup/sequence.json` の `.resume.mode` に保存されます。
優先順位はフラグ → 保存されたデフォルト → `fork` です。この設定は、レート制限フックが
自動切り替えしたときに表示するメッセージにも適用されます（後述）。

> **macOS の注意：** 再開したセッションが新アカウントで認証できるかは Claude Code の
> セッション仕様に依存します。認証できない場合でも切り替え自体は成功し、新規セッション
> で起動します。fork は新アカウントが所有するセッションを作ることでこれを回避するため、
> この問題に当たりやすいのは `same` モードです。

### カスタムエンドポイント

Anthropic 互換エンドポイントを切り替え可能なアカウントとして追加できます：

```bash
# API キー（x-api-key）型プロバイダー、キーはプロンプト入力（シェル履歴に残らない）
ccs add-endpoint openrouter --base-url https://openrouter.ai/api/v1 --token-header api_key

# Bearer トークン型プロバイダー、キーをパイプで渡す
echo "$MY_TOKEN" | ccs add-endpoint gateway --base-url https://gw.corp/v1 --token-header auth_token --key-stdin --model claude-3-5-sonnet

ccs to openrouter        # 切り替え（~/.claude/settings.json の env に ANTHROPIC_* を書き込む）
ccs to 1                 # OAuth アカウントに戻す（env から ANTHROPIC_* を削除）
```

エンドポイントへの切り替えは Claude Code の `settings.json` の `env` を変更します。
この設定は起動時に読み込まれるため、変更を反映するには **Claude Code を再起動**
してください（または `-r` / `--resume` を使用）。

エンドポイントはレート制限自動切り替えにも参加します。Usage API が存在しないため、
`ccs` はエンドポイントに直接プローブ（`/models`、次に `/messages`）を送り、認証
エラー・レート制限・サーバーエラー・タイムアウトが返った場合に次のアカウントへ
フォールバックします。

### プロフィール

```bash
ccs profile 1 work               # アカウント 1 に "work" と命名
ccs profile 2 personal           # アカウント 2 に "personal" と命名
ccs to work                      # プロフィール名で切り替え
```

### ディレクトリ連動

```bash
ccs dir ~/work 1                 # ~/work をアカウント 1 に紐づけ
ccs dir ~/personal 2             # ~/personal をアカウント 2 に紐づけ
ccs auto                         # 現在のディレクトリに基づいて切り替え
```

### レート制限自動切り替え

5時間使用量が閾値を超えたとき、自動的に次のアカウントに切り替えます。Claude Code の [PreToolUse フック](https://docs.anthropic.com/en/docs/claude-code/hooks)を利用 — ポーリングやバックグラウンドプロセスは不要です。

```bash
# セットアップ（初回のみ）— Claude Code に PreToolUse フックをインストール
ccs rate-setup                   # デフォルト閾値 80% で有効化
ccs rate-setup --threshold 70    # カスタム閾値

# 手動チェック
ccs rate-check                   # 現在の使用率を閾値と比較
ccs rate-check --auto-switch     # 閾値超過なら切り替え

# 無効化
ccs rate-setup --disable         # フックを削除して無効化
```

`rate-setup` はフックスクリプト（`hooks/ccs-rate-hook.sh`）を、まず `ccswitch.sh` と同じ場所（ソースチェックアウトと npm パッケージ）、次に `<prefix>/share/ccswitch/`（`make install` と Homebrew のインストール先）から探します。`$CCS_SHARE_DIR` で場所を上書きできます。後述の statusline スクリプトも同様です。

**仕組み:**

1. ステータスラインスクリプトが Anthropic Usage API を呼び出し、`$TMPDIR/claude-usage-cache.json`（`$TMPDIR`/`$TMP`/`$TEMP` 未設定時は `/tmp`、`$CCS_USAGE_CACHE` で上書き可）にキャッシュ
2. ツール実行前に PreToolUse フックがキャッシュを読み取り（約20ms、API コールなし）
3. 閾値を超過していれば次のアカウントに切り替え、Claude Code にツール実行を拒否させ、新しいアカウント名を通知。PreToolUse フックは実行中の Claude Code プロセス内で動くため再起動はできず、代わりに resume モードに従った復帰コマンド（`Exit and run: claude --resume <id> --fork-session`、`same` モードでは `--fork-session` なし）を提示します。再開できる会話がなければ「再起動してください」にフォールバックします
4. すべてのエラーは fail open — フックの不具合でユーザーの作業がブロックされることはありません

**前提条件:** `$TMPDIR/claude-usage-cache.json`（未設定時は `/tmp`）を定期更新するステータスラインスクリプトが必要です（[Anthropic OAuth Usage API](https://api.anthropic.com/api/oauth/usage) のデータ）。キャッシュには `five_hour.utilization`（0-100）が含まれている必要があります。

### リアクティブ自動切り替え（`ccs run`）

Paperclip/Multica などのヘッドレスオーケストレーターが `claude -p` を実行する場合、PreToolUse フックはターン途中に届く 429 を検出できません。`ccs run` はその隙間を埋めます。アクティブなアカウントでコマンドを実行し、レート制限により失敗した場合は次の健全なアカウントに切り替えてリトライします。

```bash
ccs run -- claude -p "このリポジトリを要約して"
ccs run --max-attempts 3 --timeout 120 -- claude -p "..."
```

**検出** はフォーマット非依存です。失敗したコマンドの出力を `429`・`rate_limit`・`overloaded`・`usage limit` で grep します。これらの文字列が見つからず、かつコマンドが失敗した場合は Usage API チェックにフォールバックしてアカウントの枯渇を判定します。

**フラグ:**

| フラグ | デフォルト | 説明 |
|--------|-----------|------|
| `--max-attempts N` | アカウント数 | 全アカウントにわたる最大試行回数 |
| `--limit-threshold N` | 95 | 事前チェックで使う使用率の閾値（%） |
| `--timeout SEC` | なし | 1 回の試行の時間制限。子プロセスグループを kill |
| `--no-proactive` | — | 実行前の使用率チェックをスキップ |

**終了コード:**

| コード | 意味 |
|--------|------|
| 0 | 成功 |
| コマンド自身のコード | レート制限以外の失敗（リトライなし） |
| 124 | `--timeout` でタイムアウト |
| 3 | 全アカウント枯渇。stderr に機械可読な `ccs-run: exhausted accounts=N attempts=M` を出力 |
| 2 | 内部切り替えエラー |

stdin はテンポラリファイルにスプールされ、各試行で再生されます。成功した試行の stdout のみ出力されます。

> **IMPORTANT — 冪等性:** レート制限で失敗した試行が、制限に達する前にすでに副作用のあるツール呼び出しを実行している可能性があります。デフォルトのリトライはコマンドを最初から再実行するため、副作用が重複することがあります。コマンドを冪等に設計するか、`--max-attempts 1` でリトライを無効にしてください。

> **IMPORTANT — バッファされた stdout:** 成功した試行の stdout のみ出力されます。`--output-format stream-json` イベントはリアルタイムでストリームされないため、オーケストレーターの非アクティブタイムアウトに引っかかる場合があります。

### 診断

```bash
ccs check                        # バックアップの整合性チェック（JSON、パーミッション、キーチェーン）
ccs status                       # 現在のアカウント、トークン有効期限、最終切り替え日時
ccs stats                        # アカウントごとの使用統計
```

### その他

```bash
ccs version                      # バージョン表示
ccs help                         # ヘルプ表示
```

### root での実行

認証情報とバックアップはユーザー単位（`$HOME`、macOS では Keychain）で保存されるため、
デフォルトでは `root` での実行を拒否します。root で実行すると別のホーム／Keychain を
参照してしまい、root 所有のファイルが残って通常ユーザーでの動作を壊すおそれがあります。

リスクを理解した上で（サンドボックスやコンテナでのテストなど）実行したい場合は、
`--allow-root` フラグ、または環境変数 `CCSWITCH_ALLOW_ROOT=1` でオプトアウトできます：

```bash
ccs --allow-root ls              # フラグ（コマンドの前後どちらでも可）
CCSWITCH_ALLOW_ROOT=1 ccs ls     # 環境変数
```

コンテナ内は自動検出され、フラグなしで許可されます。

### シェル統合

シェルプロファイルに以下を追加すると、補完と `ccs` エイリアスが有効になります：

**Bash** (`~/.bashrc`):

```bash
source "$(command -v ccs)" --shell-init bash 2>/dev/null
```

**Zsh** (`~/.zshrc`):

```bash
source "$(command -v ccs)" --shell-init zsh 2>/dev/null
```

**Fish** (`~/.config/fish/config.fish`):

```fish
source "$(command -v ccs)" --shell-init fish 2>/dev/null
```

## 動作要件

- Bash 3.2+
- `jq`（JSON プロセッサ）

### 依存パッケージのインストール

**macOS:**

```bash
brew install jq
```

**Ubuntu/Debian:**

```bash
sudo apt install jq
```

## 仕組み

アカウントの認証データを個別に保存・管理します：

- **macOS**: 認証情報はキーチェーンに、OAuth 情報は `~/.claude-switch-backup/` に保存
- **Linux/WSL**: 認証情報と OAuth 情報の両方を `~/.claude-switch-backup/` にアクセス制限付きで保存

切り替え時の動作：

1. 現在のアカウントの認証データをバックアップ
2. 切り替え先のアカウントの認証データを復元
3. Claude Code の認証ファイルを更新
4. いずれかのステップが失敗した場合は自動ロールバック

## トラブルシューティング

まず `ccs check` を実行してください。JSON の妥当性、ファイルパーミッション、キーチェーンエントリを検証します。

### よくある問題

| 問題 | 解決方法 |
|------|----------|
| 切り替えに失敗する | `ccs check` で診断。Claude Code が閉じていることを確認。 |
| アカウントを追加できない | Claude Code にログイン済みか確認。`jq` がインストールされているか確認。 |
| 切り替え後に Claude Code が新しいアカウントを認識しない | Claude Code を再起動するか、`ccs sw -r` を使用。 |
| どのアカウントがアクティブか分からない | `ccs ls` を実行 — アクティブなアカウントにマークが付きます。 |

## アンインストール

1. 現在のアクティブアカウントを確認: `ccs ls`
2. バックアップディレクトリを削除: `rm -rf ~/.claude-switch-backup`
3. アンインストール:
   - **make**: `sudo make uninstall`
   - **npm**: `npm uninstall -g @fairy-pitta/cc-account-switcher`
   - **手動**: `rm /usr/local/bin/ccs`

現在の Claude Code ログインはそのまま維持されます。

## コントリビュート

コントリビュート歓迎です！ガイドラインは [CONTRIBUTING.md](CONTRIBUTING.md) をご覧ください。

## セキュリティ

- macOS の認証情報はシステムキーチェーンに保存
- すべてのバックアップファイルは `600` パーミッション（所有者のみ読み書き可能）
- `ccs check` で整合性チェック

## 謝辞

このプロジェクトは [ming86/cc-account-switcher](https://github.com/ming86/cc-account-switcher) のフォークです。Claude Code のマルチアカウント切り替えの基盤を構築してくださったオリジナルの開発者に感謝します。

## ライセンス

MIT License — 詳細は [LICENSE](LICENSE) ファイルをご覧ください。
