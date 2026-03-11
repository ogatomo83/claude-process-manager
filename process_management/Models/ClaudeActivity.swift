import Foundation

enum ClaudeActivity: Hashable {
    case thinking       // Claudeが考え中 (最後のメッセージがuser)
    case toolRunning    // ツール実行中 (最後がtool_use)
    case responding     // テキスト応答中 (最後がassistant text)
    case idle           // 入力待ち (最後がassistant textで時間が経っている)

    var label: String {
        switch self {
        case .thinking: return "Thinking..."
        case .toolRunning: return "Running tool..."
        case .responding: return "Responding..."
        case .idle: return "Waiting for input"
        }
    }
}
