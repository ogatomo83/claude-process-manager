import Foundation
import Combine

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

    private func activateAndLaunchClaude(projectName: String, path: String) {
        let script = """
        tell application "System Events"
            set processNames to {"Electron", "Code", "Visual Studio Code"}
            repeat with procName in processNames
                if exists process procName then
                    tell process procName
                        set targetWindows to every window whose name contains "\(projectName)"
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
        try? openProcess.run()
        openProcess.waitUntilExit()

        // Wait for VSCode to open
        Thread.sleep(forTimeInterval: 2.0)

        // Open terminal and type claude
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
        runAppleScript(script)
    }

    private func getOpenVSCodeProjects() -> [String] {
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

    private func runAppleScript(_ source: String) {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }
}
