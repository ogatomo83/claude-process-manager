import Foundation

enum HostApp: String {
    case vscode = "VSCode"
    case nvim = "nvim"
    case terminal = "Terminal"
    case unknown = "Unknown"
}

enum SessionStatus: Equatable {
    case active      // CPU使用中
    case idle        // 起動中だがCPU低い
    case stale       // 長時間放置(1時間以上アイドル)

    var label: String {
        switch self {
        case .active: return "実行中"
        case .idle: return "待機中"
        case .stale: return "放置"
        }
    }

    var color: String {
        switch self {
        case .active: return "green"
        case .idle: return "yellow"
        case .stale: return "gray"
        }
    }
}

struct ClaudeSession: Identifiable, Equatable {
    let id: Int32 // PID
    let projectName: String
    let projectPath: String
    let hostApp: HostApp
    let cpuPercent: Double
    let memoryMB: Double
    let elapsedTime: String
    let status: SessionStatus
    let jsonlPath: String?
    let activity: ClaudeActivity

    var pid: Int32 { id }
}
