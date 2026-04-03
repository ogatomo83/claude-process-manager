import Foundation
import Combine
import CoreGraphics

struct ProjectEntry: Identifiable {
    let id: String  // full path
    let name: String
    let parentDir: String  // "workspace" or "my-workspace"
    let path: String
    let hasClaudeSession: Bool  // currently has a Claude process running
    let isVSCodeOpen: Bool
}

final class ProjectLauncher: ObservableObject {
    @Published var projects: [ProjectEntry] = []

    private let workspaceDirs = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("workspace").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("my-workspace").path,
    ]

    func scan(activeSessions: [ClaudeSession]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let openVSCodeProjects = self.getOpenVSCodeProjects()
            let activeProjectPaths = Set(activeSessions.map { $0.projectPath })

            var entries: [ProjectEntry] = []
            let fm = FileManager.default

            for dir in self.workspaceDirs {
                guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                let parentName = (dir as NSString).lastPathComponent

                for name in contents.sorted() {
                    let fullPath = "\(dir)/\(name)"
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    // Skip hidden directories
                    guard !name.hasPrefix(".") else { continue }

                    let hasSession = activeProjectPaths.contains(fullPath)
                    let isVSCodeOpen = openVSCodeProjects.contains(where: { $0.contains(name) })

                    entries.append(ProjectEntry(
                        id: fullPath,
                        name: name,
                        parentDir: parentName,
                        path: fullPath,
                        hasClaudeSession: hasSession,
                        isVSCodeOpen: isVSCodeOpen
                    ))
                }
            }

            DispatchQueue.main.async {
                self.projects = entries
            }
        }
    }

    /// Open VSCode for the directory and launch Claude in its terminal
    func launch(project: ProjectEntry) {
        DispatchQueue.global(qos: .userInitiated).async {
            if project.isVSCodeOpen {
                // VSCode is open: bring to front, open terminal, type claude
                self.activateAndLaunchClaude(projectName: project.name, path: project.path)
            } else {
                // Open VSCode first, then launch Claude
                self.openVSCodeAndLaunchClaude(path: project.path, projectName: project.name)
            }
        }
    }

    /// Sanitize input for safe inclusion in AppleScript string literals.
    /// Removes control characters (newlines, tabs) that break string context,
    /// then escapes backslashes and double quotes.
    private func sanitizeForAppleScript(_ input: String) -> String {
        let cleaned = input.filter { !$0.isNewline && ($0.asciiValue.map { $0 >= 32 } ?? true) }
        return cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func activateAndLaunchClaude(projectName: String, path: String) {
        let escaped = sanitizeForAppleScript(projectName)
        let script = """
        tell application "System Events"
            set processNames to {"Electron", "Code", "Visual Studio Code"}
            repeat with procName in processNames
                if exists process procName then
                    tell process procName
                        set targetWindows to every window whose name contains "\(escaped)"
                        if (count of targetWindows) > 0 then
                            set targetWindow to item 1 of targetWindows
                            perform action "AXRaise" of targetWindow
                            set frontmost to true
                            delay 0.3
                            -- Open new terminal: Ctrl+Shift+`
                            keystroke "`" using {control down, shift down}
                            delay 0.5
                            -- Type claude
                            keystroke "claude"
                            delay 0.1
                            key code 36
                            return
                        end if
                    end tell
                end if
            end repeat
        end tell
        """
        runAppleScript(script)
    }

    private func openVSCodeAndLaunchClaude(path: String, projectName: String) {
        // Open VSCode
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Visual Studio Code", path]
        openProcess.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        try? openProcess.run()
        openProcess.waitUntilExit()

        // Wait for VSCode to open, then type claude
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
            let script = """
            tell application "System Events"
                set processNames to {"Electron", "Code", "Visual Studio Code"}
                repeat with procName in processNames
                    if exists process procName then
                        tell process procName
                            set frontmost to true
                            delay 0.5
                            -- Open terminal: Ctrl+`
                            keystroke "`" using {control down}
                            delay 0.8
                            keystroke "claude"
                            delay 0.1
                            key code 36
                            return
                        end tell
                    end if
                end repeat
            end tell
            """
            self.runAppleScript(script)
        }
    }

    private func getOpenVSCodeProjects() -> [String] {
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

    private func runAppleScript(_ source: String) {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }
}
