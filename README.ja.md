# Claude Code マルチアカウント切り替えツール

[![CI](https://github.com/fairy-pitta/cc-account-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/fairy-pitta/cc-account-switcher/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/fairy-pitta/cc-account-switcher?style=flat&color=blue)](https://github.com/fairy-pitta/cc-account-switcher/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-brightgreen)](https://github.com/fairy-pitta/cc-account-switcher)
[![Shell](https://img.shields.io/badge/shell-bash%204.4%2B-89e051)](https://github.com/fairy-pitta/cc-account-switcher)
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
npm install -g cc-account-switcher

# インストールせずに実行
npx cc-account-switcher --help
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
```

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
   - **npm**: `npm uninstall -g cc-account-switcher`
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
