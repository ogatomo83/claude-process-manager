import Foundation

struct NvimSession: Identifiable, Equatable {
    let id: Int32                       // front nvim PID (used as card id)
    let backendPid: Int32?              // nvim --embed PID (for debug / future RPC)
    let projectName: String             // lastPathComponent of front cwd
    let projectPath: String             // front cwd
    let hostApp: HostApp                // .iterm2 or .terminal only
    let cpuPercent: Double              // front + back combined
    let memoryMB: Double                // front + back combined
    let elapsedTime: String             // front etime
    let tty: String?                    // front TTY (for iTerm2 tab switching)
    let claudeSessions: [ClaudeSession] // nested Claude sessions (0+)

    var pid: Int32 { id }
}
