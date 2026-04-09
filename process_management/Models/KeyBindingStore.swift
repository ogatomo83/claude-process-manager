import SwiftUI
import Combine
import Carbon.HIToolbox

// MARK: - Modifier

enum KeyModifier: String, Codable, CaseIterable {
    case command, shift, option, control

    var eventFlag: SwiftUI.EventModifiers {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        }
    }

    var cgFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        }
    }

    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        }
    }

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }
}

// MARK: - KeyBinding

struct KeyBinding: Codable, Equatable {
    var key: String          // Character or special key name ("space", "return", "j", etc.)
    var modifiers: [KeyModifier]

    /// Display string like "⌘⇧Space"
    var displayString: String {
        let modStr = modifiers.sorted(by: { $0.symbol < $1.symbol }).map(\.symbol).joined()
        let keyStr: String
        switch key {
        case "space": keyStr = "Space"
        case "return": keyStr = "Return"
        case "tab": keyStr = "Tab"
        case "escape": keyStr = "Esc"
        case "delete": keyStr = "Delete"
        default: keyStr = key.uppercased()
        }
        return modStr + keyStr
    }

    /// Match against SwiftUI KeyPress
    func matchesKeyPress(key pressKey: KeyEquivalent, modifiers pressMods: SwiftUI.EventModifiers) -> Bool {
        // Check modifiers match exactly
        for mod in KeyModifier.allCases {
            let binding = self.modifiers.contains(mod)
            let press = pressMods.contains(mod.eventFlag)
            if binding != press { return false }
        }

        // Check key
        switch key {
        case "space": return pressKey == .space
        case "return": return pressKey == .return
        case "tab": return pressKey == .tab
        case "escape": return pressKey == .escape
        case "delete": return pressKey == .delete
        default: return pressKey == KeyEquivalent(Character(key))
        }
    }

    /// Match against CGEvent from EventTap
    func matchesEventTap(keyCode: Int64, flags: CGEventFlags) -> Bool {
        // Check modifiers
        for mod in KeyModifier.allCases {
            let binding = self.modifiers.contains(mod)
            let event = flags.contains(mod.cgFlag)
            if binding != event { return false }
        }

        // Check key via keyCode
        let expectedKeyCode = Self.keyCodeFor(key)
        return expectedKeyCode == keyCode
    }

    // Common keyCode mapping (US keyboard layout)
    static func keyCodeFor(_ key: String) -> Int64 {
        switch key {
        case "space": return 49
        case "return": return 36
        case "tab": return 48
        case "escape": return 53
        case "delete": return 51
        case "[": return 33
        case "]": return 30
        case ",": return 43
        case ".": return 47
        case "/": return 44
        case ";": return 41
        case "'": return 39
        case "\\": return 42
        case "-": return 27
        case "=": return 24
        case "`": return 50
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case "0": return 29
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25
        default: return -1
        }
    }

    /// Reverse lookup: keyCode → key string
    static func keyForKeyCode(_ code: UInt16) -> String? {
        let map: [UInt16: String] = [
            49: "space", 36: "return", 48: "tab", 53: "escape", 51: "delete",
            33: "[", 30: "]", 43: ",", 47: ".", 44: "/", 41: ";", 39: "'",
            42: "\\", 27: "-", 24: "=", 50: "`",
            0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g",
            4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n",
            31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u",
            9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9",
        ]
        return map[code]
    }
}

// MARK: - Shortcut Action

enum ShortcutAction: String, CaseIterable {
    case toggleWindow
    case nextSession
    case prevSession
    case activateSession
    case nextCluster
    case prevCluster
    case commandPalette

    var label: String {
        switch self {
        case .toggleWindow: return "Toggle Window"
        case .nextSession: return "Next Session"
        case .prevSession: return "Previous Session"
        case .activateSession: return "Activate Session"
        case .nextCluster: return "Next Cluster"
        case .prevCluster: return "Previous Cluster"
        case .commandPalette: return "Command Palette"
        }
    }
}

// MARK: - KeyBindingStore

final class KeyBindingStore: ObservableObject {
    static let shared = KeyBindingStore()

    static let defaults: [ShortcutAction: KeyBinding] = [
        .toggleWindow:   KeyBinding(key: "space", modifiers: [.command, .shift]),
        .nextSession:    KeyBinding(key: "j", modifiers: []),
        .prevSession:    KeyBinding(key: "k", modifiers: []),
        .activateSession: KeyBinding(key: "return", modifiers: []),
        .nextCluster:    KeyBinding(key: "]", modifiers: [.command]),
        .prevCluster:    KeyBinding(key: "[", modifiers: [.command]),
        .commandPalette: KeyBinding(key: "/", modifiers: []),
    ]

    @Published var bindings: [ShortcutAction: KeyBinding] {
        didSet { save() }
    }

    private let userDefaultsKey = "com.processmanagement.keybindings"

    private init() {
        bindings = Self.defaults
        load()
    }

    func binding(for action: ShortcutAction) -> KeyBinding {
        bindings[action] ?? Self.defaults[action]!
    }

    func setBinding(_ binding: KeyBinding, for action: ShortcutAction) {
        bindings[action] = binding
    }

    func resetToDefaults() {
        bindings = Self.defaults
    }

    /// Check if a SwiftUI KeyPress matches an action
    func matches(_ action: ShortcutAction, key: KeyEquivalent, modifiers: SwiftUI.EventModifiers) -> Bool {
        binding(for: action).matchesKeyPress(key: key, modifiers: modifiers)
    }

    /// Check if a CGEvent matches an action
    func matchesEventTap(_ action: ShortcutAction, keyCode: Int64, flags: CGEventFlags) -> Bool {
        binding(for: action).matchesEventTap(keyCode: keyCode, flags: flags)
    }

    // MARK: - Persistence

    private func save() {
        let dict = bindings.mapKeys { $0.rawValue }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let dict = try? JSONDecoder().decode([String: KeyBinding].self, from: data) else { return }
        for (rawKey, binding) in dict {
            if let action = ShortcutAction(rawValue: rawKey) {
                bindings[action] = binding
            }
        }
    }
}

// MARK: - Dictionary helper

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
