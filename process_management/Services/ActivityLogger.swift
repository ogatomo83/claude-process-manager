import Foundation

final class ActivityLogger {
    static let shared = ActivityLogger()

    private let logURL: URL
    private let queue = DispatchQueue(label: "activity-logger", qos: .utility)
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("my-workspace/process_management/docs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("activity_debug.log")

        // Rotate: clear on launch
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        write("===== ActivityLogger started =====")
    }

    /// Log a state transition from ProcessMonitor (polling)
    func logPoll(pid: Int32, project: String, event: String, result: ClaudeActivity) {
        write("[POLL] pid=\(pid) project=\(project) event=\(event) → \(result.rawValue)")
    }

    /// Log a state transition from ConversationLoader (file watch, single line)
    func logStream(event: String, result: ClaudeActivity) {
        write("[STREAM] event=\(event) → \(result.rawValue)")
    }

    /// Log initial load detection
    func logInitial(event: String, result: ClaudeActivity) {
        write("[INIT] event=\(event) → \(result.rawValue)")
    }

    /// Log the actual activity change published to UI
    func logTransition(source: String, from: ClaudeActivity, to: ClaudeActivity) {
        guard from != to else { return }
        write("[TRANSITION] \(source): \(from.rawValue) → \(to.rawValue)")
    }

    private func write(_ message: String) {
        let ts = formatter.string(from: Date())
        let line = "\(ts) \(message)\n"
        queue.async { [logURL] in
            if let data = line.data(using: .utf8) {
                if let fh = try? FileHandle(forWritingTo: logURL) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                } else {
                    try? line.write(to: logURL, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
