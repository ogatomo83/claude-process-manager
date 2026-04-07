import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var store = KeyBindingStore.shared
    @State private var recordingAction: ShortcutAction? = nil
    @State private var eventMonitor: Any? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "keyboard")
                    .font(.system(size: 16))
                    .foregroundStyle(.cyan)
                Text("Keyboard Shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.1))

            // Shortcut rows
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ShortcutAction.allCases, id: \.self) { action in
                        shortcutRow(action: action)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider().overlay(Color.white.opacity(0.1))

            // Footer
            HStack {
                Button("Reset to Defaults") {
                    store.resetToDefaults()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                .font(.system(size: 12))

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 400)
        .background(Color(red: 0.1, green: 0.1, blue: 0.14))
        .onDisappear {
            stopRecording()
        }
    }

    private func shortcutRow(action: ShortcutAction) -> some View {
        let isRecording = recordingAction == action
        let binding = store.binding(for: action)

        return HStack {
            Text(action.label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))

            Spacer()

            if isRecording {
                Text("Press a key...")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .stroke(.cyan.opacity(0.6), lineWidth: 1)
                    )
            } else {
                Text(binding.displayString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.08))
                    )
            }

            Button(isRecording ? "Cancel" : "Record") {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording(action: action)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isRecording ? .orange : .cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isRecording ? .orange.opacity(0.1) : .cyan.opacity(0.1))
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isRecording ? Color.cyan.opacity(0.04) : Color.clear)
    }

    private func startRecording(action: ShortcutAction) {
        stopRecording()
        recordingAction = action

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode

            // Escape cancels recording
            if keyCode == 53 {
                stopRecording()
                return nil
            }

            // Ignore modifier-only presses
            guard let key = KeyBinding.keyForKeyCode(keyCode) else {
                return nil
            }

            var mods: [KeyModifier] = []
            if event.modifierFlags.contains(.command) { mods.append(.command) }
            if event.modifierFlags.contains(.shift) { mods.append(.shift) }
            if event.modifierFlags.contains(.option) { mods.append(.option) }
            if event.modifierFlags.contains(.control) { mods.append(.control) }

            let newBinding = KeyBinding(key: key, modifiers: mods)
            store.setBinding(newBinding, for: action)
            stopRecording()

            return nil // consume the event
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        recordingAction = nil
    }
}
