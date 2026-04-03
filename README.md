# Process Management

macOS メニューバー常駐アプリ。実行中の Claude Code セッションをキャンバス上で可視化・操作する。

## 必要な環境

- **macOS**: 14.0 (Sonoma) 以降
- **Xcode**: 15.0 以降

## ビルド方法

### Xcode

1. `process_management.xcodeproj` を Xcode で開く
2. Signing & Capabilities で **Team** を自分の Apple Developer アカウントに変更する
3. `Cmd+R` でビルド＆実行

### コマンドライン

```bash
# コード署名なしでビルド
xcodebuild \
  -project process_management.xcodeproj \
  -scheme process_management \
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR=./build \
  build

# 起動
open ./build/process_management.app
```

> **注意**: コード署名なしでビルドした場合、一部の機能（Apple Events による他アプリの操作など）が制限される可能性があります。フル機能を利用するには Xcode からビルドし、コード署名を有効にしてください。

## 必要な権限

初回起動時に以下の権限を求められます：

- **アクセシビリティ**: グローバルホットキー (`Cmd+Shift+Space`) の検知に必要
- **Apple Events (オートメーション)**: VSCode / Cursor など他アプリのウィンドウ操作に必要

## 基本操作

| 操作 | 説明 |
|------|------|
| `Cmd+Shift+Space` | パネルの表示/非表示 |
| カードをクリック | セッション選択 |
| カードをダブルクリック | VSCode を開いてパネルを閉じる |
| キャンバスをドラッグ | パン |
| `Cmd+スクロール` | ズーム |
| カード右クリック | グループへの追加/削除 |

## ツールバー

| ボタン | 説明 |
|--------|------|
| Eye / VSCode | 表示フィルタ（全ホストアプリ / VSCode のみ） |
| VSCode ON | VSCode ウィンドウカードの表示切替 |
| グループモード | Custom / Host App / Activity / VSCode |
| Lasso | ドラッグでカードを囲んでグループ化 |
| +/- / % | ズーム |
| Reset | キャンバスの位置・ズームをリセット |
| Layout | カードを自動配置 |
| Launch | 新しい Claude セッションを起動 |
| Keyboard | Vimmer モードの ON/OFF |

## Vimmer モード

キーボードだけでセッションを切り替える機能。ツールバーのキーボードアイコン、またはメニューバーの「Vimmer Mode」から ON/OFF を切り替える。設定はアプリ再起動後も維持される。

| キー | 動作 |
|------|------|
| `j` | 次のセッションを選択 |
| `k` | 前のセッションを選択 |
| `Enter` | 選択中のセッションの VSCode を開いてパネルを閉じる |

- 未選択状態で `j` → 先頭を選択、`k` → 末尾を選択
- リスト端ではループする（末尾 → 先頭、先頭 → 末尾）
- Vimmer モード OFF のときは j/k/Enter は通常のキー入力として透過する

## グループ機能

カードをグループ化して視覚的にまとめられる。

- **手動グループ**: Lasso ツールで囲む、またはカード右クリックから追加
- **自動グループ**: ツールバーのグループモードで Host App / Activity / VSCode を選択
- **ルールベース**: グループエディタでホストアプリ・アクティビティ・パスプレフィックスのルールを設定
- **スタイル**: Nebula / Constellation / Aurora / Circuit の 4 種類

## メニューバー

| 項目 | 説明 |
|------|------|
| Show / Hide | パネルの表示切替 (`Cmd+Shift+Space`) |
| Vimmer Mode | Vimmer モードの ON/OFF |
| Quit | アプリ終了 |
