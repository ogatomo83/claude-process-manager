import SwiftUI
import AppKit

@main
struct process_managementApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NotificationService.shared.requestPermission()
    }

    var body: some Scene {
        MenuBarExtra("プロセス管理", systemImage: "cpu") {
            Button("表示 / 非表示    \u{2318}\u{21E7}Space") {
                GlobalHotkeyService.shared.toggleWindow()
            }
            Divider()
            Button("設定...") {
                AppDelegate.toggleSettings()
            }
            .keyboardShortcut(",")
            Divider()
            Button("終了") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel?
    private static var settingsWindow: NSWindow?
    private var settingsHotkeyMonitor: Any?

    static func toggleSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.orderOut(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "設定"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock and Cmd+Tab
        NSApp.setActivationPolicy(.accessory)

        // Close any windows SwiftUI may have created
        for window in NSApp.windows where !(window is NSPanel) {
            window.close()
        }

        // Create floating panel (80% of screen)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 700)
        let panelRect = NSRect(
            x: screenFrame.origin.x + screenFrame.width * 0.1,
            y: screenFrame.origin.y + screenFrame.height * 0.1,
            width: screenFrame.width * 0.8,
            height: screenFrame.height * 0.8
        )
        let panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hostingView = NSHostingView(rootView: ContentView())
        panel.contentView = hostingView

        self.panel = panel

        GlobalHotkeyService.shared.start(window: panel)

        // ⌘, to toggle settings from any window in the app
        settingsHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 43, event.modifierFlags.contains(.command) {
                AppDelegate.toggleSettings()
                return nil
            }
            return event
        }

        // Show on first launch
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyService.shared.stop()
        if let monitor = settingsHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            settingsHotkeyMonitor = nil
        }
    }

    // Hide instead of destroying when close button (X) is clicked
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
