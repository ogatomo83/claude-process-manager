# Claude Code セッション管理アプリ 開発計画

## コンセプト

複数のClaude Codeセッションを一覧で見渡し、
**クリックするだけで該当VSCodeウィンドウが最前面に出てくる**ハブアプリ。
加えて、各セッションの会話内容もリアルタイムで閲覧できる。

---

## 技術調査結果 (実証済み)

### 1. VSCodeウィンドウの特定・前面化 → 可能

```applescript
-- プロジェクト名でウィンドウを特定し、最前面に出す
tell application "System Events"
    tell process "Code"
        set targetWindow to (first window whose name contains "process_management")
        perform action "AXRaise" of targetWindow
        set frontmost to true
    end tell
end tell
```

VSCodeのウィンドウタイトルにはプロジェクト名が含まれる:
- `"Preview plan.md — process_management"`
- `".DS_Store — life-backend"`

→ Claudeのcwdから取得したプロジェクト名でマッチ可能。

### 2. Claude PID → VSCode の紐付け → 可能

プロセスツリーを親方向にたどり、VSCode (`Code Helper` or `Electron`) に到達するか確認:

```
claude (PID 50458)
  → /bin/zsh (PID 48789)
    → Code Helper (PID 3433)     ← VSCode のターミナル
      → Electron (PID 2268)      ← VSCode 本体
```

### 3. 会話データの読み取り → 可能

`~/.claude/projects/<project-dir>/<session-id>.jsonl` にリアルタイムで書き込まれる。
`DispatchSource` でファイル変更を監視すれば、ポーリング不要で即時反映。

---

## Phase 1: MVP

### 画面構成

```
┌─────────────────────────────────────────────────┐
│  Claude Sessions                                │
├──────────────────┬──────────────────────────────┤
│                  │                              │
│ ● process_mgmt  │  [USER] プロセス管理の        │
│   ↳ VSCode      │  アプリを作りたいです         │
│   CPU: 35% 528MB│                              │
│   5分前          │  [CLAUDE] まずプロジェクト    │
│                  │  の現状を確認させて...        │
│ ○ life-backend  │                              │
│   ↳ nvim        │  [TOOL] Bash: ps aux...      │
│   CPU: 0% 232MB │                              │
│   2日前          │  [CLAUDE] 調査結果を          │
│                  │  まとめると...               │
│ ○ news          │                              │
│   ↳ nvim        │                              │
│   CPU: 0% 105MB │                              │
│   2日前          │                              │
│                  │                              │
├──────────────────┴──────────────────────────────┤
│  クリックでVSCodeウィンドウを最前面に表示         │
└─────────────────────────────────────────────────┘
```

### 機能

1. **セッション一覧 (左ペイン)**
   - プロジェクト名、ホスト環境 (VSCode / nvim / ターミナル)
   - CPU / メモリ / 経過時間
   - 状態インジケータ (実行中 / アイドル / 放置)

2. **ワンクリック ウィンドウ切替**
   - セッション行をクリック → AppleScript で VSCode ウィンドウを `AXRaise` + `frontmost`
   - nvim の場合はターミナルウィンドウを前面に

3. **会話ビュー (右ペイン)**
   - user / assistant メッセージをチャット形式で表示
   - ツール実行は折りたたみ表示
   - JSONLファイル監視によるリアルタイム更新

### ファイル構成

```
process_management/
├── Models/
│   ├── ClaudeSession.swift          # PID, project, hostApp, status
│   └── ConversationMessage.swift    # role, content, toolName, timestamp
├── Services/
│   ├── ProcessMonitor.swift         # claude プロセス検出 + cwd + 親プロセス判定
│   ├── SessionResolver.swift        # cwd → JSONL ファイル特定
│   ├── ConversationLoader.swift     # JSONL パース + DispatchSource 監視
│   └── WindowSwitcher.swift         # AppleScript 実行 (AXRaise)
├── Views/
│   ├── ContentView.swift            # 2ペインレイアウト
│   ├── SessionListView.swift        # 左ペイン: セッション一覧
│   ├── SessionRowView.swift         # 各セッションの行
│   ├── ConversationView.swift       # 右ペイン: 会話表示
│   └── MessageBubbleView.swift      # メッセージバブル
├── process_managementApp.swift
└── Assets.xcassets/
```

### 実装ステップ

1. `ClaudeSession` / `ConversationMessage` モデル定義
2. `ProcessMonitor`: `ps` + `lsof` でClaude検出、親プロセスチェーンでホストアプリ判定
3. `SessionResolver`: cwd → `~/.claude/projects/` 内の最新JSONL特定
4. `ConversationLoader`: JSONLパース + `DispatchSource` ファイル監視
5. `WindowSwitcher`: `NSAppleScript` でウィンドウ前面化
6. `ContentView`: 2ペインレイアウト組み立て
7. `SessionListView` + `ConversationView` 実装
8. 全体結合 + Timer によるプロセス情報の定期更新

---

## Phase 2: UX改善

- メニューバー常駐 (稼働セッション数バッジ)
- 放置セッション検出 → 通知
- セッション終了ボタン

## Phase 3: 履歴・検索

- 終了済みセッションの会話閲覧
- キーワード検索 (全セッション横断)

---

## 技術的な考慮事項

| 項目 | 方針 |
|------|------|
| ウィンドウ前面化 | `NSAppleScript` で System Events 経由。アクセシビリティ権限が必要 |
| ホストアプリ判定 | プロセスツリーを親方向に5段階たどり、`Code` / `nvim` / `Terminal` を検出 |
| JSONL監視 | `DispatchSource.makeFileSystemObjectSource(.write)` で変更検知。差分読み込み |
| 大きいJSONL | 末尾200行のみ初期読み込み。上スクロールで遅延ロード |
| サンドボックス | 無効化必須 (他プロセス情報取得 + `~/.claude` アクセス + AppleScript) |
| 権限 | アクセシビリティ権限 (System Preferences → Privacy → Accessibility) |
