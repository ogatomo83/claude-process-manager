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

        return ClaudeSession(
            id: pid,
            projectName: projectName,
            projectPath: cwd,
            hostApp: hostApp,
            cpuPercent: cpuPercent,
            memoryMB: rssMB,
            elapsedTime: elapsed,
            status: status,
            jsonlPath: jsonlPath
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
