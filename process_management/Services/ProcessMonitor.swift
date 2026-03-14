import Foundation
import Combine
import CoreGraphics

final class ProcessMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var vscodeWindows: [VSCodeWindow] = []
    @Published var detectVSCode: Bool = false

    private var timer: Timer?
    private let sessionResolver = SessionResolver()
    private var previousActivities: [Int32: ClaudeActivity] = [:]
    /// idle遷移のデバウンス: 2回連続idleで初めてidle確定
    private var idleCountByPid: [Int32: Int] = [:]
    /// ファイル更新時刻キャッシュ: 変化なしならJSONL再読みスキップ
    private var cachedModDates: [Int32: Date] = [:]
    private var cachedActivities: [Int32: ClaudeActivity] = [:]

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

                    // idle遷移のデバウンス: 2回連続idleで初めて確定
                    if session.activity == .idle {
                        self.idleCountByPid[session.id, default: 0] += 1
                    } else {
                        self.idleCountByPid[session.id] = 0
                    }

                    if let previous {
                        // デバウンス: 初回idleは遷移をスキップ（previousを維持）
                        let effectiveActivity: ClaudeActivity
                        if session.activity == .idle, previous != .idle,
                           (self.idleCountByPid[session.id] ?? 0) < 2 {
                            effectiveActivity = previous
                            ActivityLogger.shared.logPoll(pid: session.id, project: session.projectName, event: "idle-debounce(count=\(self.idleCountByPid[session.id] ?? 0))", result: previous)
                        } else {
                            effectiveActivity = session.activity
                        }

                        ActivityLogger.shared.logTransition(source: "ProcessMonitor(\(session.projectName))", from: previous, to: effectiveActivity)
                        if previous != .idle, effectiveActivity == .idle {
                            NotificationService.shared.notifyTurnCompleted(sessionName: session.projectName)
                        }
                        self.previousActivities[session.id] = effectiveActivity
                    } else {
                        self.previousActivities[session.id] = session.activity
                    }
                }

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

        // ファイル更新時刻が変わっていなければキャッシュを返す
        // ただし idle 以外はstale判定が必要なので再チェック
        let activity: ClaudeActivity
        if let path = jsonlPath,
           let modDate = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date,
           let cachedMod = cachedModDates[pid],
           cachedMod == modDate,
           let cached = cachedActivities[pid],
           cached == .idle {
            activity = cached
        } else {
            activity = detectActivity(jsonlPath: jsonlPath, cpuPercent: cpuPercent)
            if let path = jsonlPath,
               let modDate = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date {
                cachedModDates[pid] = modDate
            }
            cachedActivities[pid] = activity
        }

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

    /// Lightweight activity detection: read last 64KB of JSONL.
    /// Only `system::turn_duration` is treated as a definitive idle signal.
    /// When turn_duration follows an assistant with tool_use, the session is
    /// waiting for user approval, not idle.
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
        let project = (path as NSString).lastPathComponent.prefix(8)

        // stale判定: ファイルが一定時間更新されていない場合の扱い
        // - assistant(text) + stale → idle（ターン完了、turn_durationなし）
        // - user(text) + stale → thinking（API応答待ち、時間がかかることがある）
        // - progress/tool_use + stale → waitingPermission（ユーザー承認待ち）
        // - assistant(thinking) + stale → thinking（思考に時間がかかる）
        let isStaleForIdle = secondsSinceModified > 10

        var sawTurnDuration = false

        for line in lines.reversed() {
            let s = String(line)

            guard let jsonData = s.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            switch type {
            case "file-history-snapshot":
                continue

            case "progress":
                // progressがある = ツールは承認済み・実行中
                // サブエージェント等はprogressが断続的（10-15秒間隔）なのでstaleでもtoolRunning
                ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "progress", result: .toolRunning)
                return .toolRunning

            case "system":
                let subtype = json["subtype"] as? String ?? ""
                if subtype == "turn_duration" {
                    sawTurnDuration = true
                    continue
                }
                if subtype == "compact_boundary" {
                    let r: ClaudeActivity = secondsSinceModified > 30 ? .idle : .compacting
                    ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "compact_boundary(\(Int(secondsSinceModified))s)", result: r)
                    return r
                }
                continue

            case "user":
                if let message = json["message"] as? [String: Any],
                   let contentArray = message["content"] as? [[String: Any]] {
                    let isToolResult = contentArray.contains { ($0["type"] as? String) == "tool_result" }
                    if isToolResult { continue }
                }
                // user(text) + stale → まだthinking（APIは10秒以上かかることがある）
                let r: ClaudeActivity = sawTurnDuration ? .idle : .thinking
                ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "user(text) sawTD=\(sawTurnDuration)", result: r)
                return r

            case "assistant":
                guard let msg = json["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else {
                    let r: ClaudeActivity = (sawTurnDuration || isStaleForIdle) ? .idle : .responding
                    ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "assistant(no-content) sawTD=\(sawTurnDuration) stale=\(isStaleForIdle)", result: r)
                    return r
                }
                let blockTypes = blocks.compactMap { $0["type"] as? String }
                let blockDesc = blockTypes.joined(separator: ",")

                // thinking only → thinking（staleでもthinking維持）
                if blockTypes.contains("thinking") && !blockTypes.contains("text") && !blockTypes.contains("tool_use") {
                    let r: ClaudeActivity = sawTurnDuration ? .idle : .thinking
                    ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "assistant(\(blockDesc)) sawTD=\(sawTurnDuration)", result: r)
                    return r
                }
                // tool_use → staleならwaitingPermission（承認待ち）
                if blockTypes.contains("tool_use") {
                    if sawTurnDuration {
                        ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "assistant(tool_use) sawTD=true", result: .idle)
                        return .idle
                    }
                    let toolName = blocks.first(where: { $0["type"] as? String == "tool_use" })?["name"] as? String ?? "?"
                    ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "assistant(tool_use:\(toolName))", result: .waitingPermission)
                    return .waitingPermission
                }
                // assistant(text) + stale → idle（ターン完了、turn_durationなし）
                let r: ClaudeActivity = (sawTurnDuration || isStaleForIdle) ? .idle : .responding
                ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "assistant(\(blockDesc)) sawTD=\(sawTurnDuration) stale=\(isStaleForIdle)", result: r)
                return r

            default:
                continue
            }
        }
        return .idle
    }

    private func getVSCodeWindowTitles() -> [String] {
        // Use CGWindowListCopyWindowInfo instead of AppleScript
        // Works across all Spaces including full-screen windows
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let vscodeOwners: Set<String> = ["Electron", "Code", "Visual Studio Code"]
        var titles: [String] = []

        for window in windowList {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  vscodeOwners.contains(owner),
                  let name = window[kCGWindowName as String] as? String,
                  !name.isEmpty else { continue }
            titles.append(name)
        }
        return titles
    }

    private func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
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
