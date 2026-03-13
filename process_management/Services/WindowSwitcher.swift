import Foundation
import AppKit

final class WindowSwitcher {

    /// Activate the host app for a Claude session.
    /// For VSCode: uses `open -a` which correctly switches Spaces (even full-screen).
    /// For Terminal/nvim: uses NSRunningApplication + AXUIElement.
    func activate(session: ClaudeSession) {
        switch session.hostApp {
        case .vscode:
            openWithVSCode(path: session.projectPath)
        case .nvim, .terminal, .unknown:
            activateViaProcessTree(pid: session.pid, projectName: session.projectName)
        }
    }

    /// Activate VSCode window for a VSCodeWindow card (no Claude PID).
    func activateVSCodeWindow(projectName: String) {
        // Try to find the project path from the window title
        // VSCode titles: "project_name — Visual Studio Code"
        // Fall back to just activating VSCode
        if let vscode = findRunningVSCode() {
            vscode.activate(options: .activateAllWindows)
            raiseWindow(pid: vscode.processIdentifier, titleContaining: projectName)
        }
    }

    // MARK: - VSCode activation via `open -a`

    /// `open -a "Visual Studio Code" /path` tells macOS to open the folder.
    /// If already open, VSCode brings that window to front.
    /// macOS handles Space switching natively (including full-screen).
    private func openWithVSCode(path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Visual Studio Code", path]
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    // MARK: - Terminal/nvim activation via process tree + AXUIElement

    private func activateViaProcessTree(pid: Int32, projectName: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let app = self.findHostApp(pid: pid) else { return }
            DispatchQueue.main.async {
                app.activate(options: .activateAllWindows)
                self.raiseWindow(pid: app.processIdentifier, titleContaining: projectName)
            }
        }
    }

    /// Use AXUIElement API to find a window by title and raise it
    private func raiseWindow(pid: pid_t, titleContaining keyword: String) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else { continue }

            if title.contains(keyword) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }

    // MARK: - Process helpers

    private func findRunningVSCode() -> NSRunningApplication? {
        let vscodeIDs: Set<String> = [
            "com.microsoft.VSCode",
            "com.visualstudio.code.oss",
            "com.todesktop.230313mzl4w4u92",
        ]
        return NSWorkspace.shared.runningApplications.first {
            vscodeIDs.contains($0.bundleIdentifier ?? "")
        }
    }

    /// Walk up the process tree from Claude PID to find the host application
    private func findHostApp(pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<6 {
            let ppidStr = shell("ps -o ppid= -p \(current)").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ppid = Int32(ppidStr), ppid > 1 else { break }

            if let app = NSRunningApplication(processIdentifier: ppid),
               app.bundleIdentifier != nil {
                return app
            }
            current = ppid
        }
        return nil
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
