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

    /// PID → HostApp cache (hostApp doesn't change for a living process)
    private var hostAppCache: [Int32: HostApp] = [:]
    /// PID → cwd cache (cwd doesn't change for a living process)
    private var cwdCache: [Int32: String] = [:]

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

            // Clean up caches for dead PIDs
            let alivePIDs = Set(pids)
            self.hostAppCache = self.hostAppCache.filter { alivePIDs.contains($0.key) }
            self.cwdCache = self.cwdCache.filter { alivePIDs.contains($0.key) }

            // Build process tree lookup table once: pid → (ppid, comm)
            let processTree = self.buildProcessTree()

            // Batch ps info for all claude PIDs in one call
            let psInfoMap = self.batchPSInfo(pids: pids)

            // Batch lsof for PIDs that don't have cached cwd
            let uncachedPIDs = pids.filter { self.cwdCache[$0] == nil }
            if !uncachedPIDs.isEmpty {
                let cwdMap = self.batchCWD(pids: uncachedPIDs)
                for (pid, cwd) in cwdMap {
                    self.cwdCache[pid] = cwd
                }
            }

            var newSessions: [ClaudeSession] = []

            for pid in pids {
                if let session = self.buildSession(
                    pid: pid,
                    psInfo: psInfoMap[pid],
                    processTree: processTree
                ) {
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

                // Fix 3: Only update @Published if sessions actually changed
                if newSessions != self.sessions {
                    self.sessions = newSessions
                }
                if newVSCodeWindows != self.vscodeWindows {
                    self.vscodeWindows = newVSCodeWindows
                }
            }
        }
    }

    private func findClaudePIDs() -> [Int32] {
        let output = shell("pgrep -x claude")
        return output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Build a full process tree in one shell call: pid → (ppid, comm)
    private func buildProcessTree() -> [Int32: (ppid: Int32, comm: String)] {
        let output = shell("ps -eo pid=,ppid=,comm=")
        var tree: [Int32: (ppid: Int32, comm: String)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces)),
                  let ppid = Int32(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let comm = String(parts[2]).trimmingCharacters(in: .whitespaces)
            tree[pid] = (ppid: ppid, comm: comm)
        }
        return tree
    }

    /// Batch get ps info (cpu, rss, etime) for multiple PIDs in one call
    private struct PSInfo {
        let cpuPercent: Double
        let rssMB: Double
        let elapsed: String
    }

    private func batchPSInfo(pids: [Int32]) -> [Int32: PSInfo] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map { String($0) }.joined(separator: ",")
        let output = shell("ps -o pid=,pcpu=,rss=,etime= -p \(pidList)")
        var result: [Int32: PSInfo] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let cpu = Double(parts[1]) ?? 0.0
            let rss = (Double(parts[2]) ?? 0.0) / 1024.0
            let etime = String(parts[3])
            result[pid] = PSInfo(cpuPercent: cpu, rssMB: rss, elapsed: etime)
        }
        return result
    }

    /// Batch get cwd for multiple PIDs in one lsof call
    private func batchCWD(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map { String($0) }.joined(separator: ",")
        let output = shell("lsof -a -d cwd -p \(pidList) 2>/dev/null")
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // lsof output: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            guard parts.count >= 9 else { continue }
            guard let pid = Int32(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let fd = String(parts[3])
            guard fd == "cwd" else { continue }
            // NAME is the last field (may contain spaces, so join remaining)
            let name = parts[8...].joined(separator: " ")
            if !name.isEmpty {
                result[pid] = name
            }
        }
        return result
    }

    private func buildSession(
        pid: Int32,
        psInfo: PSInfo?,
        processTree: [Int32: (ppid: Int32, comm: String)]
    ) -> ClaudeSession? {
        guard let info = psInfo else { return nil }

        // Use cached cwd
        guard let cwd = cwdCache[pid], !cwd.isEmpty else { return nil }

        let projectName = (cwd as NSString).lastPathComponent

        // Use cached hostApp or detect via process tree lookup
        let hostApp: HostApp
        if let cached = hostAppCache[pid] {
            hostApp = cached
        } else {
            let detected = detectHostApp(pid: pid, processTree: processTree)
            hostAppCache[pid] = detected
            hostApp = detected
        }

        let status = determineStatus(cpu: info.cpuPercent, elapsed: info.elapsed)
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
            activity = detectActivity(jsonlPath: jsonlPath, cpuPercent: info.cpuPercent)
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
            cpuPercent: info.cpuPercent,
            memoryMB: info.rssMB,
            elapsedTime: info.elapsed,
            status: status,
            jsonlPath: jsonlPath,
            activity: activity
        )
    }

    /// Detect host app using pre-built process tree (no shell calls)
    private func detectHostApp(pid: Int32, processTree: [Int32: (ppid: Int32, comm: String)]) -> HostApp {
        var current = pid
        for _ in 0..<6 {
            guard let entry = processTree[current], entry.ppid > 1 else { break }
            let comm = entry.comm

            // Check parent's comm
            if let parentEntry = processTree[entry.ppid] {
                let parentComm = parentEntry.comm
                if parentComm.contains("Code") || parentComm.contains("Electron") {
                    return .vscode
                }
                if parentComm.contains("Terminal") || parentComm.contains("iTerm") {
                    return .terminal
                }
            }

            current = entry.ppid
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
                    if isToolResult {
                        // tool_result = ツール実行済み → Claudeが次のレスポンスを考え始める
                        // API呼び出しに10秒以上かかることがあるのでstaleでもthinking
                        let r: ClaudeActivity = sawTurnDuration ? .idle : .thinking
                        ActivityLogger.shared.logPoll(pid: 0, project: String(project), event: "user(tool_result) sawTD=\(sawTurnDuration)", result: r)
                        return r
                    }
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
                // tool_use → waitingPermission（承認待ち）
                // tool_resultが後にあるケースはuser(tool_result)で先にthinkingを返すため到達しない
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
            // Read pipe BEFORE waitUntilExit to avoid deadlock when output > 64KB
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
