import Foundation
import Combine
import CoreGraphics

enum ClusterKind: Hashable {
    case hostApp(HostApp)
    case vscodeWindows

    var label: String {
        switch self {
        case .hostApp(let app): return app.rawValue
        case .vscodeWindows: return "VSCode Windows"
        }
    }

    var icon: String {
        switch self {
        case .hostApp(let app): return app.icon
        case .vscodeWindows: return "macwindow.on.rectangle"
        }
    }
}

final class ProcessMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var vscodeWindows: [VSCodeWindow] = []
    /// Currently displayed cluster. nil = auto-select first discovered.
    @Published var selectedCluster: ClusterKind? = nil
    @Published var discoveredClusters: [ClusterKind] = []

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

            // Detect hostApp for all PIDs (lightweight, uses cache)
            for pid in pids where self.hostAppCache[pid] == nil {
                self.hostAppCache[pid] = self.detectHostApp(pid: pid, processTree: processTree)
            }

            // Build discovered clusters (stable order: HostApp.allCases then vscodeWindows)
            let discoveredHostSet = Set(pids.compactMap { self.hostAppCache[$0] })
            var clusters: [ClusterKind] = HostApp.allCases
                .filter { discoveredHostSet.contains($0) }
                .map { .hostApp($0) }

            // Always detect VSCode windows (lightweight CGWindowList)
            let allTitles = self.getVSCodeWindowTitles()
            // Ensure cwd is cached for all VSCode-hosted PIDs (needed for exclusion filter)
            let vscodePIDs = pids.filter { self.hostAppCache[$0] == .vscode }
            let uncachedVSCodePIDs = vscodePIDs.filter { self.cwdCache[$0] == nil }
            if !uncachedVSCodePIDs.isEmpty {
                let cwdMap = self.batchCWD(pids: uncachedVSCodePIDs)
                for (pid, cwd) in cwdMap {
                    self.cwdCache[pid] = cwd
                }
            }
            let claudeVSCodeProjects = Set(
                vscodePIDs.compactMap { pid -> String? in
                    guard let cwd = self.cwdCache[pid] else { return nil }
                    return (cwd as NSString).lastPathComponent
                }
            )
            let vsWindowTitles = allTitles.filter { title in
                !claudeVSCodeProjects.contains { title.contains($0) }
            }

            // Debug: dump detection results to /tmp/
            let debugLines = [
                "[\(Date())] allTitles(\(allTitles.count)): \(allTitles)",
                "claudeVSCodeProjects: \(claudeVSCodeProjects)",
                "vsWindowTitles(\(vsWindowTitles.count)): \(vsWindowTitles)"
            ].joined(separator: "\n")
            try? debugLines.write(toFile: "/tmp/pm_vscode_debug.log", atomically: true, encoding: .utf8)

            if !vsWindowTitles.isEmpty {
                clusters.append(.vscodeWindows)
            }

            // Resolve active cluster
            let activeCluster = self.selectedCluster ?? clusters.first

            // Filter PIDs to active hostApp cluster — skip heavy work for other clusters
            let visiblePIDs: [Int32]
            if case .hostApp(let app) = activeCluster {
                visiblePIDs = pids.filter { self.hostAppCache[$0] == app }
            } else {
                visiblePIDs = []  // vscodeWindows cluster shows no Claude sessions
            }

            // Batch ps info for visible claude PIDs only
            let psInfoMap = self.batchPSInfo(pids: visiblePIDs)

            // Batch lsof for visible PIDs that don't have cached cwd
            let uncachedPIDs = visiblePIDs.filter { self.cwdCache[$0] == nil }
            if !uncachedPIDs.isEmpty {
                let cwdMap = self.batchCWD(pids: uncachedPIDs)
                for (pid, cwd) in cwdMap {
                    self.cwdCache[pid] = cwd
                }
            }

            var newSessions: [ClaudeSession] = []

            for pid in visiblePIDs {
                if let session = self.buildSession(
                    pid: pid,
                    psInfo: psInfoMap[pid],
                    processTree: processTree
                ) {
                    newSessions.append(session)
                }
            }

            // Always build VSCode window models so they're ready when cluster is switched
            let newVSCodeWindows = vsWindowTitles.map { VSCodeWindow(windowTitle: $0) }

            DispatchQueue.main.async {
                // Update discovered clusters
                if clusters != self.discoveredClusters {
                    self.discoveredClusters = clusters
                }
                // Auto-select first discovered if none selected or current vanished
                if self.selectedCluster == nil || !clusters.contains(self.selectedCluster!) {
                    self.selectedCluster = clusters.first
                }

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
        let output = run(executable: "/usr/bin/pgrep", arguments: ["-x", "claude"])
        return output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Build a full process tree in one call: pid → (ppid, comm)
    private func buildProcessTree() -> [Int32: (ppid: Int32, comm: String)] {
        let output = run(executable: "/bin/ps", arguments: ["-eo", "pid=,ppid=,comm="])
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
        let output = run(executable: "/bin/ps", arguments: ["-o", "pid=,pcpu=,rss=,etime=", "-p", pidList])
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
        let output = run(executable: "/usr/sbin/lsof", arguments: ["-a", "-d", "cwd", "-p", pidList])
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
        // Single FileManager call to avoid duplicate I/O
        let activity: ClaudeActivity
        let modDate: Date? = jsonlPath.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date
        }
        if let modDate,
           let cachedMod = cachedModDates[pid],
           cachedMod == modDate,
           let cached = cachedActivities[pid],
           cached == .idle {
            activity = cached
        } else {
            activity = detectActivity(jsonlPath: jsonlPath, cpuPercent: info.cpuPercent)
            if let modDate {
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
        for _ in 0..<10 {
            guard let entry = processTree[current], entry.ppid > 1 else { break }

            if let parentEntry = processTree[entry.ppid] {
                let parentComm = parentEntry.comm
                // VSCode: match "Visual Studio" to exclude other Electron apps (Slack, Discord)
                if parentComm.contains("Visual Studio") || parentComm.contains("Code Helper") {
                    return .vscode
                }
                // iTerm2: "iTerm" matches both iTerm2.app and iTermServer
                if parentComm.contains("iTerm") {
                    return .iterm2
                }
                // macOS Terminal.app: full path to avoid false positives
                if parentComm.contains("Terminal.app") || parentComm.hasSuffix("/Terminal") {
                    return .terminal
                }
            }

            current = entry.ppid
        }
        return .unknown
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
        // AppleScript: get window names from "Code" process
        let script = """
        tell application "System Events"
            if exists (process "Code") then
                return name of every window of process "Code"
            end if
        end tell
        return {}
        """
        let output = run(executable: "/usr/bin/osascript", arguments: ["-e", script])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // AppleScript returns comma-separated list: "title1, title2, ..."
        return trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Run a command with arguments directly (no shell interpretation).
    /// Includes a timeout to prevent hangs from stalled processes.
    private func run(executable: String, arguments: [String], timeout: TimeInterval = 5.0) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            ActivityLogger.shared.logError("Process launch failed: \(executable) - \(error)")
            return ""
        }

        // Schedule timeout to terminate hung processes
        let timeoutItem = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        // Read pipe BEFORE waitUntilExit to avoid deadlock when output > 64KB
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()

        return String(data: data, encoding: .utf8) ?? ""
    }
}
