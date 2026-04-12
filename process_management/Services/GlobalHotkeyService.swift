import AppKit
import Carbon.HIToolbox

final class GlobalHotkeyService {
    static let shared = GlobalHotkeyService()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var managedWindow: NSWindow?
    // Strong reference — weak was the bug: NSRunningApplication got released between show and hide.
    private var previousApp: NSRunningApplication?
    private var previousAppPID: pid_t?

    private init() {}

    // MARK: - Public

    func start(window: NSWindow) {
        managedWindow = window
        guard checkAccessibility() else { return }
        installEventTap()
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func toggleWindow() {
        guard let window = managedWindow else { return }
        // For accessory apps, window.isVisible is the reliable indicator.
        if window.isVisible && NSApp.isActive {
            hideWindow(restorePreviousApp: true)
        } else {
            showWindow()
        }
    }

    /// Show the window and remember which app was frontmost so it can be restored on dismiss.
    func showWindow() {
        guard let window = managedWindow else { return }
        // Only record previous app when transitioning from hidden → shown
        if !window.isVisible || !NSApp.isActive {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != getpid() {
                previousApp = front
                previousAppPID = front.processIdentifier
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide the window. Optionally restore focus to the app that was frontmost before we showed.
    /// Pass `restorePreviousApp: false` when the caller is activating a different target app
    /// (e.g. launching VSCode, switching to a terminal session).
    func hideWindow(restorePreviousApp: Bool) {
        guard let window = managedWindow else { return }

        if restorePreviousApp {
            // Resolve the target: prefer the stored reference, fall back to PID lookup in case
            // the reference was released or the app restarted.
            var target: NSRunningApplication? = previousApp
            if target == nil || target?.isTerminated == true, let pid = previousAppPID {
                target = NSRunningApplication(processIdentifier: pid)
            }

            if let target, !target.isTerminated {
                // Activate the other app first — this yields our active status to it,
                // then orderOut our window so macOS doesn't try to re-activate us.
                target.activate()
                DispatchQueue.main.async {
                    window.orderOut(nil)
                }
            } else {
                // No valid previous app — hide the app entirely; macOS will pick next in order.
                window.orderOut(nil)
                NSApp.hide(nil)
            }
        } else {
            window.orderOut(nil)
        }

        previousApp = nil
        previousAppPID = nil
    }

    // MARK: - Accessibility

    private func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Event Tap

    private func installEventTap() {
        // Callback must be a C function pointer — use a static-compatible closure
        let callback: CGEventTapCallBack = { _, type, event, _ in
            // Re-enable if the OS disabled the tap due to timeout
            if type == .tapDisabledByTimeout {
                if let tap = GlobalHotkeyService.shared.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            if KeyBindingStore.shared.matchesEventTap(.toggleWindow, keyCode: keyCode, flags: flags) {
                DispatchQueue.main.async {
                    GlobalHotkeyService.shared.toggleWindow()
                }
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        ) else {
            print("[GlobalHotkeyService] Failed to create event tap — accessibility permission may be missing")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
