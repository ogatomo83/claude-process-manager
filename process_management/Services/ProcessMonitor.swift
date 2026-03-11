import Foundation
import Combine

final class ProcessMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var vscodeWindows: [VSCodeWindow] = []
    @Published var detectVSCode: Bool = false

    private var timer: Timer?
    private let sessionResolver = SessionResolver()
    private var previousActivities: [Int32: ClaudeActivity] = [:]

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

            // Detect VSCode windows without Claude
            var newVSCodeWindows: [VSCodeWindow] = []
            if self.detectVSCode {
                let allTitles = self.getVSCodeWindowTitles()
                let claudeProjects = Set(
                    newSessions
                        .filter { $0.hostApp == .vscode }
                        .map { $0.projectName }
                )
                newVSCodeWindows = allTitles
                    .filter { title in
                        !claudeProjects.contains { projName in title.contains(projName) }
                    }
                    .map { VSCodeWindow(windowTitle: $0) }
            }

            DispatchQueue.main.async {
                // Detect idle transitions and send notifications
                for session in newSessions {
                    let previous = self.previousActivities[session.id]
                    if let previous, previous != .idle, session.activity == .idle {
                        NotificationService.shared.notifyTurnCompleted(sessionName: session.projectName)
                    }
                }
                self.previousActivities = Dictionary(
                    uniqueKeysWithValues: newSessions.map { ($0.id, $0.activity) }
                )

                self.sessions = newSessions
                self.vscodeWindows = newVSCodeWindows
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
        let activity = detectActivity(jsonlPath: jsonlPath, cpuPercent: cpuPercent)

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

    /// Lightweight activity detection: read last 64KB of JSONL
    /// Idle detection: turn_duration (definitive), or file-history-snapshot
    /// after assistant text (turn_duration is not always written).
    /// During extended thinking ("Ruminating..."), no JSONL writes and low CPU
    /// (thinking happens server-side), so staleness/CPU heuristics don't work.
    private func detectActivity(jsonlPath: String?, cpuPercent: Double) -> ClaudeActivity {
        guard let path = jsonlPath,
              let fh = FileHandle(forReadingAtPath: path) else { return .idle }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else { return .idle }

        let fileURL = URL(fileURLWithPath: path)
        let modDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? Date.distantPast
        let secondsSinceModified = Date().timeIntervalSince(modDate)

        let chunkSize: UInt64 = min(fileSize, 65536)
        fh.seek(toFileOffset: fileSize - chunkSize)
        let data = fh.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else { return .idle }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        // Track whether file-history-snapshot was seen before hitting assistant/user
        // If assistant text is followed by file-history-snapshot → turn is complete
        var sawFileHistorySnapshot = false

        for line in lines.reversed() {
            let s = String(line)

            guard let jsonData = s.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            switch type {
            case "file-history-snapshot":
                sawFileHistorySnapshot = true
                continue

            // progress events = tool is actively producing output
            case "progress":
                return secondsSinceModified > 5 ? .idle : .toolRunning

            case "system":
                let subtype = json["subtype"] as? String ?? ""
                if subtype == "turn_duration" {
                    return .idle
                }
                if subtype == "compact_boundary" {
                    return secondsSinceModified > 10 ? .idle : .compacting
                }
                continue

            case "user":
                return .thinking

            case "assistant":
                guard let msg = json["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else {
                    return secondsSinceModified > 5 ? .idle : .responding
                }
                let blockTypes = blocks.compactMap { $0["type"] as? String }

                // Extended thinking block (no text/tool_use yet)
                if blockTypes.contains("thinking") && !blockTypes.contains("text") && !blockTypes.contains("tool_use") {
                    return .thinking
                }
                // tool_use without subsequent progress/tool_result → awaiting approval
                if blockTypes.contains("tool_use") {
                    return .waitingPermission
                }
                // Text response followed by file-history-snapshot → turn complete
                if sawFileHistorySnapshot {
                    return .idle
                }
                // Still streaming — fall back to staleness check
                return secondsSinceModified > 5 ? .idle : .responding

            default:
                continue
            }
        }
        return .idle
    }

    private func getVSCodeWindowTitles() -> [String] {
        let script = """
        tell application "System Events"
            set windowTitles to {}
            set processNames to {"Electron", "Code", "Visual Studio Code"}
            repeat with procName in processNames
                if exists process procName then
                    tell process procName
                        set windowTitles to name of every window
                    end tell
                    exit repeat
                end if
            end repeat
            return windowTitles
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)

        guard let listDesc = result else { return [] }
        var titles: [String] = []
        for i in 1...listDesc.numberOfItems {
            if let item = listDesc.atIndex(i)?.stringValue {
                titles.append(item)
            }
        }
        return titles
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
