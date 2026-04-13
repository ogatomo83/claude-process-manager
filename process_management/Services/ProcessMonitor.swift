import Foundation
import Combine
import CoreGraphics

enum ClusterKind: Hashable {
    case hostApp(HostApp)
    case vscodeWindows
    case nvim

    var label: String {
        switch self {
        case .hostApp(let app): return app.rawValue
        case .vscodeWindows: return "VSCode Windows"
        case .nvim: return "Neovim"
        }
    }

    var icon: String {
        switch self {
        case .hostApp(let app): return app.icon
        case .vscodeWindows: return "macwindow.on.rectangle"
        case .nvim: return "keyboard"
        }
    }
}

final class ProcessMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var vscodeWindows: [VSCodeWindow] = []
    @Published var nvimSessions: [NvimSession] = []
    /// Currently displayed cluster. nil = auto-select first discovered.
    @Published var selectedCluster: ClusterKind? = nil
    @Published var discoveredClusters: [ClusterKind] = []
    /// HostApps that currently have at least one Claude session
    @Published var activeHostApps: Set<HostApp> = []

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
    /// PID → TTY cache (TTY doesn't change for a living process)
    private var ttyCache: [Int32: String] = [:]

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
            let nvimPIDs = self.findNvimPIDs()

            // Build process tree lookup table once: pid → (ppid, comm)
            let processTree = self.buildProcessTree()

            // Separate nvim into front (TTY-attached) and back (--embed) processes
            let (frontNvimPIDs, backNvimPIDs) = self.separateNvimFrontBack(nvimPIDs)

            // Clean up caches for dead PIDs (include nvim pids in alive set)
            let alivePIDs = Set(pids)
                .union(frontNvimPIDs)
                .union(backNvimPIDs)
            self.hostAppCache = self.hostAppCache.filter { alivePIDs.contains($0.key) }
            self.cwdCache = self.cwdCache.filter { alivePIDs.contains($0.key) }
            self.ttyCache = self.ttyCache.filter { alivePIDs.contains($0.key) }

            // Detect hostApp for all PIDs (lightweight, uses cache)
            for pid in pids where self.hostAppCache[pid] == nil {
                self.hostAppCache[pid] = self.detectHostApp(pid: pid, processTree: processTree)
            }
            for pid in frontNvimPIDs where self.hostAppCache[pid] == nil {
                self.hostAppCache[pid] = self.detectHostApp(pid: pid, processTree: processTree)
            }
            for pid in backNvimPIDs where self.hostAppCache[pid] == nil {
                self.hostAppCache[pid] = self.detectHostApp(pid: pid, processTree: processTree)
            }

            // Filter front nvim PIDs to iTerm2/Terminal-hosted only
            let filteredFrontNvimPIDs = frontNvimPIDs.filter {
                let host = self.hostAppCache[$0]
                return host == .iterm2 || host == .terminal
            }
            let frontSet = Set(filteredFrontNvimPIDs)

            // Map each backend nvim to its front nvim (backend's parent chain contains front)
            var backToFront: [Int32: Int32] = [:]
            for back in backNvimPIDs {
                var cur = back
                for _ in 0..<5 {
                    guard let entry = processTree[cur] else { break }
                    if frontSet.contains(entry.ppid) {
                        backToFront[back] = entry.ppid
                        break
                    }
                    cur = entry.ppid
                }
            }

            // Build discovered clusters (stable order: HostApp.allCases then vscodeWindows)
            // VSCode and iTerm2 are always shown; others only when sessions exist
            let discoveredHostSet = Set(pids.compactMap { self.hostAppCache[$0] })
            let alwaysShown: Set<HostApp> = [.vscode, .iterm2]
            var clusters: [ClusterKind] = HostApp.allCases
                .filter { alwaysShown.contains($0) || discoveredHostSet.contains($0) }
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

            if !filteredFrontNvimPIDs.isEmpty {
                clusters.append(.nvim)
            }

            // Resolve active cluster
            let activeCluster = self.selectedCluster ?? clusters.first

            // Filter PIDs to active hostApp cluster — skip heavy work for other clusters
            var visiblePIDs: [Int32]
            if case .hostApp(let app) = activeCluster {
                visiblePIDs = pids.filter { self.hostAppCache[$0] == app }
            } else {
                visiblePIDs = []  // vscodeWindows/nvim cluster shows no bare Claude sessions
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

            // Resolve iTerm2 session TTY for tab switching.
            // Claude inside nvim :terminal has a pseudo-TTY that isn't an iTerm2 session;
            // we walk up the process tree and use the ancestor TTY closest to iTermServer.
            let itermPIDsNeedingTTY = visiblePIDs.filter {
                self.hostAppCache[$0] == .iterm2 && self.ttyCache[$0] == nil
            }
            if !itermPIDsNeedingTTY.isEmpty {
                // Collect ancestor chains for each iTerm2 claude PID
                var allAncestorPIDs = Set<Int32>()
                var ancestorChains: [Int32: [Int32]] = [:]
                for pid in itermPIDsNeedingTTY {
                    var chain: [Int32] = []
                    var current = pid
                    for _ in 0..<15 {
                        chain.append(current)
                        guard let entry = processTree[current], entry.ppid > 1 else { break }
                        current = entry.ppid
                    }
                    ancestorChains[pid] = chain
                    allAncestorPIDs.formUnion(chain)
                }
                // One batch ps call for all ancestor TTYs
                let ttyMap = self.batchTTY(pids: Array(allAncestorPIDs))
                // For each claude PID, walk from iTerm side (reversed) to find the session TTY
                for pid in itermPIDsNeedingTTY {
                    guard let chain = ancestorChains[pid] else { continue }
                    for ancestor in chain.reversed() {
                        if let tty = ttyMap[ancestor] {
                            self.ttyCache[pid] = tty
                            break
                        }
                    }
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

            // Build nvim sessions only when the nvim cluster is active (heavy work gating).
            var newNvimSessions: [NvimSession] = []
            let nvimClusterActive: Bool = {
                if case .nvim = activeCluster { return true }
                return false
            }()
            if nvimClusterActive && !filteredFrontNvimPIDs.isEmpty {
                // Cache cwd for uncached front nvim PIDs
                let uncachedNvimCwdPIDs = filteredFrontNvimPIDs.filter { self.cwdCache[$0] == nil }
                if !uncachedNvimCwdPIDs.isEmpty {
                    let cwdMap = self.batchCWD(pids: uncachedNvimCwdPIDs)
                    for (pid, cwd) in cwdMap {
                        self.cwdCache[pid] = cwd
                    }
                }

                // Batch ps info for front + back nvim PIDs
                let allNvimPIDs = filteredFrontNvimPIDs + backNvimPIDs
                let nvimPSInfo = self.batchPSInfo(pids: allNvimPIDs)

                // Resolve TTY for iTerm2 front nvim PIDs (reuse existing iTerm2 walking logic)
                let itermNvimNeedingTTY = filteredFrontNvimPIDs.filter {
                    self.hostAppCache[$0] == .iterm2 && self.ttyCache[$0] == nil
                }
                if !itermNvimNeedingTTY.isEmpty {
                    // Front nvim has a real TTY directly — no ancestor walk needed
                    let ttyMap = self.batchTTY(pids: itermNvimNeedingTTY)
                    for (pid, tty) in ttyMap {
                        self.ttyCache[pid] = tty
                    }
                }

                for front in filteredFrontNvimPIDs {
                    // Find backend for this front (inverse map from backToFront)
                    let back = backToFront.first(where: { $0.value == front })?.key
                    if let nvs = self.buildNvimSession(
                        frontPid: front,
                        backPid: back,
                        psInfoFront: nvimPSInfo[front],
                        psInfoBack: back.flatMap { nvimPSInfo[$0] }
                    ) {
                        newNvimSessions.append(nvs)
                    }
                }
            }

            DispatchQueue.main.async {
                // Update discovered clusters and active host apps
                if clusters != self.discoveredClusters {
                    self.discoveredClusters = clusters
                }
                if discoveredHostSet != self.activeHostApps {
                    self.activeHostApps = discoveredHostSet
                }
                // Auto-select: use default cluster setting, fallback to first discovered
                if self.selectedCluster == nil || !clusters.contains(self.selectedCluster!) {
                    let defaultRaw = UserDefaults.standard.string(forKey: "com.processmanagement.defaultCluster") ?? ""
                    let defaultCluster: ClusterKind? = {
                        if defaultRaw == "nvim" { return .nvim }
                        if defaultRaw == "vscodeWindows" { return .vscodeWindows }
                        if let h = HostApp(rawValue: defaultRaw) { return .hostApp(h) }
                        return nil
                    }()
                    if let dc = defaultCluster, clusters.contains(dc) {
                        self.selectedCluster = dc
                    } else {
                        self.selectedCluster = clusters.first
                    }
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
                if newNvimSessions != self.nvimSessions {
                    self.nvimSessions = newNvimSessions
                }
            }
        }
    }

    private func findClaudePIDs() -> [Int32] {
        let output = run(executable: "/usr/bin/pgrep", arguments: ["-x", "claude"])
        return output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func findNvimPIDs() -> [Int32] {
        let output = run(executable: "/usr/bin/pgrep", arguments: ["-x", "nvim"])
        return output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Separate nvim PIDs into front (TTY-attached) and back (`--embed`) processes
    /// in a single ps call. Backend nvim has tty="??" or args containing "--embed".
    private func separateNvimFrontBack(_ nvimPIDs: [Int32]) -> (front: [Int32], back: [Int32]) {
        guard !nvimPIDs.isEmpty else { return ([], []) }
        let pidList = nvimPIDs.map(String.init).joined(separator: ",")
        let output = run(executable: "/bin/ps",
                         arguments: ["-o", "pid=,tty=,args=", "-p", pidList])
        var front: [Int32] = []
        var back: [Int32] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]) else { continue }
            let tty = String(parts[1])
            let args = String(parts[2])
            let isBack = args.contains("--embed") || tty == "??" || tty.isEmpty
            if isBack {
                back.append(pid)
            } else {
                front.append(pid)
                if self.ttyCache[pid] == nil {
                    self.ttyCache[pid] = "/dev/\(tty)"
                }
            }
        }
        return (front, back)
    }

    private func buildNvimSession(
        frontPid: Int32,
        backPid: Int32?,
        psInfoFront: PSInfo?,
        psInfoBack: PSInfo?
    ) -> NvimSession? {
        guard let front = psInfoFront else { return nil }
        guard let cwd = cwdCache[frontPid], !cwd.isEmpty else { return nil }
        guard let host = hostAppCache[frontPid],
              host == .iterm2 || host == .terminal else { return nil }

        let projectName = (cwd as NSString).lastPathComponent
        let cpu = front.cpuPercent + (psInfoBack?.cpuPercent ?? 0)
        let rss = front.rssMB + (psInfoBack?.rssMB ?? 0)

        return NvimSession(
            id: frontPid,
            backendPid: backPid,
            projectName: projectName,
            projectPath: cwd,
            hostApp: host,
            cpuPercent: cpu,
            memoryMB: rss,
            elapsedTime: front.elapsed,
            tty: ttyCache[frontPid]
        )
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

    /// Batch get TTY for multiple PIDs in one ps call
    private func batchTTY(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map { String($0) }.joined(separator: ",")
        let output = run(executable: "/bin/ps", arguments: ["-o", "pid=,tty=", "-p", pidList])
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let tty = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard tty != "??" && !tty.isEmpty else { continue }
            // ps returns "ttysXXX" → convert to "/dev/ttysXXX"
            result[pid] = "/dev/\(tty)"
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
            activity = ActivityDetector.detect(jsonlPath: jsonlPath, enableLogging: true)
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
            activity: activity,
            tty: ttyCache[pid]
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
