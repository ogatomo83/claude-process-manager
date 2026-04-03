# Audit TODO (2026-04-03)

5人のエージェント部隊による包括的監査結果。

## Phase 1 — 即座（安全性 + クラッシュ防止）

- [x] **`groupBounds()` force unwrap 修正** (Critical)
  - `CanvasWorkspaceView.swift:1773-1776`
  - 空配列で `min()!` → クラッシュ
  - 修正: `guard !positions.isEmpty` + 1パス min/max 計算
  - 報告: コード開発者, テストエンジニア, パフォーマンスおじいちゃん

- [x] **`WindowSwitcher.shell()` パイプ順序修正** (High)
  - `WindowSwitcher.swift:106-123`
  - `waitUntilExit()` → `readDataToEndOfFile()` の順序がデッドロックを起こす
  - 修正: read と wait の順序を入れ替え + Process.arguments 方式に移行
  - 報告: セキュリティエンジニア, テストエンジニア

- [x] **AppleScript インジェクション対策** (Critical)
  - `ProjectLauncher.swift:75-104`
  - `projectName` のエスケープが不十分
  - 修正: `sanitizeForAppleScript()` で制御文字除去 + エスケープ強化
  - 報告: セキュリティエンジニア

- [x] **`shell()` を `Process.arguments` 方式に移行** (Critical/Medium)
  - `ProcessMonitor.swift` / `WindowSwitcher.swift`
  - 文字列補間でシェルコマンド構築 → コマンドインジェクションリスク
  - 修正: 全 shell() を run(executable:arguments:) に置換。/bin/sh 経由を廃止
  - 報告: セキュリティエンジニア, コード開発者

## Phase 2 — 今週中（信頼性 + パフォーマンス）

- [x] **`evaluateGroupRules` メンバー除去ロジック追加** (High)
  - `CanvasWorkspaceView.swift:1743-1753`
  - ルールに合致しなくなったセッションがグループに残り続ける
  - 修正: memberPIDs を matchingPIDs で置換（stale メンバー除去）
  - 報告: テストエンジニア, パフォーマンスおじいちゃん

- [x] **`cardPositions` 死んだPID クリーンアップ** (High/Medium)
  - `CanvasWorkspaceView.swift`
  - セッション終了後も Dictionary にエントリが残り続ける
  - 修正: `cleanupStaleCardPositions()` を sessions.count 変更時に呼び出し
  - 報告: SwiftUI/UX, テストエンジニア, コード開発者

- [x] **ConversationLoader JSON パース最適化** (High)
  - `ConversationLoader.swift:111-149`
  - ツール実行中10Hz で JSON パース → CPU 5-10%
  - 修正: `{` プレフィックスチェック + `file-history-snapshot` スキップ
  - 報告: パフォーマンスおじいちゃん

- [x] **`ProcessMonitor.shell()` エラーハンドリング改善** (Medium)
  - `ProcessMonitor.swift`
  - エラー時空文字列 → 全セッション消失に見える
  - 修正: `ActivityLogger.logError()` 追加 + run() でエラーログ出力
  - 報告: テストエンジニア, セキュリティエンジニア, コード開発者

- [ ] **アクティビティ検出ロジック重複の解消** (High)
  - `ProcessMonitor.swift:308-422` と `ConversationLoader.swift:247-326`
  - ほぼ同一の `detectActivity()` ロジックが2箇所に存在
  - 修正: 共通の `ActivityDetector` サービスに抽出
  - 報告: コード開発者

## Phase 3 — 次スプリント（堅牢性）

- [x] **shell() タイムアウト追加** (High)
  - `ProcessMonitor.swift`
  - シェルコマンドがハングした場合のタイムアウトなし
  - 修正: run() に DispatchWorkItem ベースの 5秒タイムアウト追加
  - 報告: テストエンジニア

- [x] **ConversationLoader `deinit { stop() }` 追加** (Medium)
  - `ConversationLoader.swift`
  - deinit なしで FileHandle リーク可能性
  - 修正: deinit { stop() } 追加
  - 報告: テストエンジニア

- [x] **ConversationLoader TOCTOU 対策** (Medium)
  - `ConversationLoader.swift:111-149`
  - ファイルローテーション時に `lastReadOffset` がリセットされない
  - 修正: `fileSize < lastReadOffset` で offset リセット
  - 報告: テストエンジニア, セキュリティエンジニア

- [x] **symlink チェック追加** (High)
  - `SessionResolver.swift:22-40`
  - symlink 経由で任意ファイル読み取り可能
  - 修正: `URL.resourceValues(forKeys: [.isSymbolicLinkKey])` でスキップ
  - 報告: セキュリティエンジニア

- [ ] **アクセシビリティ対応** (Medium)
  - 全 View ファイル
  - VoiceOver ラベル、Dynamic Type、Tab ナビゲーション欠如
  - 報告: SwiftUI/UX スペシャリスト

- [x] **ActivityLogger ログの機密情報サニタイズ** (Medium)
  - `ActivityLogger.swift`
  - Bash コマンドやファイルパスがそのままログに記録される
  - 修正: project は 20文字、event は 100文字に制限 + 改行除去
  - 報告: セキュリティエンジニア

- [x] **FileManager.attributesOfItem 重複呼び出し削除** (Medium)
  - `ProcessMonitor.swift:224-241`
  - 同一パスに対して2回 attributesOfItem を呼んでいた
  - 修正: 1回の呼び出し結果を変数に保持して再利用
  - 報告: パフォーマンスおじいちゃん

- [x] **`groupBounds()` 4回配列生成 → 1パス化** (Medium)
  - `CanvasWorkspaceView.swift:1772-1781`
  - `positions.map(\.x).min()` を4回呼ぶ → 1パスで min/max 計算
  - 修正: Phase 1 の force unwrap 修正と同時に1パス化済み
  - 報告: パフォーマンスおじいちゃん

- [ ] **ProcessMonitor God Object 分割** (High/長期)
  - `ProcessMonitor.swift`
  - プロセス検出、アクティビティ検出、VSCode検出、キャッシュ管理が1クラスに集中
  - 修正: `ProcessDetector`, `ActivityDetector`, `VSCodeWindowDetector` に分割
  - 報告: コード開発者
