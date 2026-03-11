import SwiftUI

enum ClaudeActivity: String, Hashable, Codable {
    case thinking           // Claudeが考え中 (最後のメッセージがuser)
    case toolRunning        // ツール実行中 (progressイベントあり)
    case responding         // テキスト応答中 (最後がassistant text)
    case waitingPermission  // 許可待ち (tool_useブロック後、progressなし)
    case compacting         // コンパクト中 (compact_boundaryイベント直後)
    case idle               // 入力待ち (ファイル更新が5秒以上前)

    var label: String {
        switch self {
        case .thinking: return "Thinking..."
        case .toolRunning: return "Running tool..."
        case .responding: return "Responding..."
        case .waitingPermission: return "Awaiting approval..."
        case .compacting: return "Compacting..."
        case .idle: return "Waiting for input"
        }
    }

    var color: Color {
        switch self {
        case .thinking: return .purple
        case .toolRunning: return .orange
        case .responding: return .green
        case .waitingPermission: return .yellow
        case .compacting: return .teal
        case .idle: return .cyan
        }
    }

    var icon: String {
        switch self {
        case .thinking: return "brain"
        case .toolRunning: return "gearshape"
        case .responding: return "text.bubble"
        case .waitingPermission: return "hand.raised"
        case .compacting: return "arrow.triangle.2.circlepath"
        case .idle: return "moon.zzz"
        }
    }
}
