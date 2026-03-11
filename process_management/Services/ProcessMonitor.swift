import Foundation
import Combine

final class ProcessMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []

    private var timer: Timer?
    private let sessionResolver = SessionResolver()

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let pids = self.findClaudePIDs()
            var newSessions: [ClaudeSession] = []

            for pid in pids {
                if let session = self.buildSession(pid: pid) {
                    newSessions.append(session)
                }
            }

            DispatchQueue.main.async {
                self.sessions = newSessions
            }
        }
    }

    private func findClaudePIDs() -> [Int32] {
        let output = shell("pgrep -x claude")
        return output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func buildSession(pid: Int32) -> ClaudeSession? {
        // Get process info via ps
        let psOutput = shell("ps -o pid=,pcpu=,rss=,etime= -p \(pid)")
        let parts = psOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }

        let cpuPercent = Double(parts[1]) ?? 0.0
        let rssMB = (Double(parts[2]) ?? 0.0) / 1024.0
        let elapsed = String(parts[3])

        // Get cwd via lsof
        let lsofOutput = shell("lsof -p \(pid) 2>/dev/null | awk '$4==\"cwd\"{print $NF}'")
        let cwd = lsofOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else { return nil }

        let projectName = (cwd as NSString).lastPathComponent
        let hostApp = detectHostApp(pid: pid)
        let status = determineStatus(cpu: cpuPercent, elapsed: elapsed)
        let jsonlPath = sessionResolver.resolveJSONLPath(cwd: cwd)
        let activity = detectActivity(jsonlPath: jsonlPath)

        return ClaudeSession(
            id: pid,
            projectName: projectName,
            projectPath: cwd,
            hostApp: hostApp,
            cpuPercent: cpuPercent,
            memoryMB: rssMB,
            elapsedTime: elapsed,
            status: status,
            jsonlPath: jsonlPath,
            activity: activity
        )
    }

    private func detectHostApp(pid: Int32) -> HostApp {
        var current = pid
        for _ in 0..<6 {
            let ppidStr = shell("ps -o ppid= -p \(current)").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ppid = Int32(ppidStr), ppid > 1 else { break }

            let comm = shell("ps -o comm= -p \(ppid)").trimmingCharacters(in: .whitespacesAndNewlines)

            if comm.contains("Code") || comm.contains("Electron") {
                return .vscode
            }
            if comm.contains("nvim") || comm.contains("vim") {
                return .nvim
            }
            if comm.contains("Terminal") || comm.contains("iTerm") {
                return .terminal
            }

            current = ppid
        }
        return .terminal
    }

    private func determineStatus(cpu: Double, elapsed: String) -> SessionStatus {
        if cpu > 1.0 {
            return .active
        }
        // Check if elapsed > 1 hour
        if elapsed.contains("-") || isOverOneHour(elapsed) {
            return .stale
        }
        return .idle
    }

    private func isOverOneHour(_ elapsed: String) -> Bool {
        // Format: [[DD-]HH:]MM:SS
        let parts = elapsed.split(separator: ":")
        if parts.count >= 3 {
            // HH:MM:SS or more
            return true
        }
        if parts.count == 2, let minutes = Int(parts[0]), minutes >= 60 {
            return true
        }
        return false
    }

    /// Lightweight activity detection: read last 2KB of JSONL
    private func detectActivity(jsonlPath: String?) -> ClaudeActivity {
        guard let path = jsonlPath,
              let fh = FileHandle(forReadingAtPath: path) else { return .idle }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else { return .idle }

        // Check file modification time to distinguish responding vs idle
        let fileURL = URL(fileURLWithPath: path)
        let modDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? Date.distantPast
        let secondsSinceModified = Date().timeIntervalSince(modDate)
        let isStale = secondsSinceModified > 5 // no writes for 5 seconds → turn is done

        let chunkSize: UInt64 = min(fileSize, 2048)
        fh.seek(toFileOffset: fileSize - chunkSize)
        let data = fh.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else { return .idle }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        // Check if there are progress entries (= tool is actively producing output)
        let hasProgress = lines.contains { $0.contains("\"progress\"") }

        for line in lines.reversed() {
            let s = String(line)

            guard let jsonData = s.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            switch type {
            case "user":
                return isStale ? .idle : .thinking
            case "assistant":
                guard let msg = json["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else {
                    return isStale ? .idle : .responding
                }
                for block in blocks {
                    if block["type"] as? String == "tool_use" {
                        // progress entries exist → tool is running
                        // no progress → tool hasn't started (waiting for approval)
                        if hasProgress && !isStale {
                            return .toolRunning
                        }
                        return .idle
                    }
                }
                return isStale ? .idle : .responding
            default:
                continue
            }
        }
        return .idle
    }

    private func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
