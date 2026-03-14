import AppKit
import Carbon.HIToolbox

final class GlobalHotkeyService {
    static let shared = GlobalHotkeyService()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var managedWindow: NSWindow?

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
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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

            // ⌘⇧Space: keyCode 49, cmd + shift
            let requiredFlags: CGEventFlags = [.maskCommand, .maskShift]
            if keyCode == 49
                && flags.contains(requiredFlags)
                && !flags.contains(.maskControl)
                && !flags.contains(.maskAlternate)
            {
                DispatchQueue.main.async {
                    GlobalHotkeyService.shared.toggleWindow()
                }
                // Consume the event so it doesn't propagate
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
