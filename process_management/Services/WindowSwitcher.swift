import Foundation

final class WindowSwitcher {
    /// Bring the VSCode window containing the given project name to front
    func activateVSCodeWindow(projectName: String) {
        // VSCode may appear as "Electron", "Code", or "Visual Studio Code"
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
                            return
                        end if
                    end tell
                end if
            end repeat
        end tell
        """
        runAppleScript(script)
    }

    /// Bring a Terminal window to front (for nvim/terminal sessions)
    func activateTerminalWindow(projectName: String) {
        // Try Terminal.app first, then iTerm2
        let script = """
        tell application "System Events"
            -- Try Terminal.app
            if exists process "Terminal" then
                tell process "Terminal"
                    set targetWindows to every window whose name contains "\(projectName)"
                    if (count of targetWindows) > 0 then
                        set targetWindow to item 1 of targetWindows
                        perform action "AXRaise" of targetWindow
                        set frontmost to true
                        return
                    end if
                end tell
            end if
            -- Try iTerm2
            if exists process "iTerm2" then
                tell process "iTerm2"
                    set targetWindows to every window whose name contains "\(projectName)"
                    if (count of targetWindows) > 0 then
                        set targetWindow to item 1 of targetWindows
                        perform action "AXRaise" of targetWindow
                        set frontmost to true
                        return
                    end if
                end tell
            end if
        end tell
        """
        runAppleScript(script)
    }

    /// Activate the appropriate window based on host app
    func activate(session: ClaudeSession) {
        switch session.hostApp {
        case .vscode:
            activateVSCodeWindow(projectName: session.projectName)
        case .nvim, .terminal, .unknown:
            activateTerminalWindow(projectName: session.projectName)
        }
    }

    private func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error {
                print("AppleScript error: \(error)")
            }
        }
    }
}
