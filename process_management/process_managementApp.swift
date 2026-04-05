import SwiftUI
import AppKit

@main
struct process_managementApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NotificationService.shared.requestPermission()
    }

    var body: some Scene {
        MenuBarExtra("Process Management", systemImage: "cpu") {
            Button("Show / Hide    \u{2318}\u{21E7}Space") {
                GlobalHotkeyService.shared.toggleWindow()
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock and Cmd+Tab
        NSApp.setActivationPolicy(.accessory)

        // Close any windows SwiftUI may have created
        for window in NSApp.windows where !(window is NSPanel) {
            window.close()
        }

        // Create floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
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
        panel.center()

        let hostingView = NSHostingView(rootView: ContentView())
        panel.contentView = hostingView

        self.panel = panel

        GlobalHotkeyService.shared.start(window: panel)

        // Show on first launch
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyService.shared.stop()
    }

    // Hide instead of destroying when close button (X) is clicked
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
