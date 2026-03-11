import SwiftUI

enum GroupRule: Identifiable, Equatable {
    case hostApp(HostApp)
    case activity(ClaudeActivity)
    case pathPrefix(String)

    var id: String {
        switch self {
        case .hostApp(let app): return "host:\(app.rawValue)"
        case .activity(let act): return "activity:\(act.label)"
        case .pathPrefix(let p): return "path:\(p)"
        }
    }

    var displayLabel: String {
        switch self {
        case .hostApp(let app): return "Host: \(app.rawValue)"
        case .activity(let act): return "Activity: \(act.label)"
        case .pathPrefix(let p): return "Path: \(p)"
        }
    }

    func matches(_ session: ClaudeSession) -> Bool {
        switch self {
        case .hostApp(let app):
            return session.hostApp == app
        case .activity(let act):
            return session.activity == act
        case .pathPrefix(let prefix):
            return session.projectPath.hasPrefix(prefix)
        }
    }
}

struct CanvasGroup: Identifiable {
    let id: UUID
    var name: String
    var color: Color
    var memberPIDs: Set<Int32>
    var position: CGPoint  // center of group
    var size: CGSize       // auto-calculated from members
    var rules: [GroupRule] = []

    // Visual style
    var style: GroupStyle

    enum GroupStyle: String, CaseIterable {
        case nebula      // glowing gradient blob
        case constellation  // star-field connected dots
        case aurora      // flowing aurora-like waves
        case circuit     // tech circuit board lines
    }

    static let presetColors: [Color] = [
        .cyan, .purple, .pink, .orange, .green,
        .mint, .indigo, .teal, .yellow, .red,
    ]

    static let presetNames = [
        "Alpha", "Beta", "Gamma", "Delta", "Epsilon",
        "Nova", "Nebula", "Pulsar", "Quasar", "Zenith",
    ]

    static func randomPreset(memberPIDs: Set<Int32> = [], position: CGPoint = .zero) -> CanvasGroup {
        CanvasGroup(
            id: UUID(),
            name: presetNames.randomElement()!,
            color: presetColors.randomElement()!,
            memberPIDs: memberPIDs,
            position: position,
            size: .zero,
            rules: [],
            style: GroupStyle.allCases.randomElement()!
        )
    }
}

enum GroupingMode: String, CaseIterable {
    case custom = "Custom"
    case hostApp = "Host App"
    case activity = "Activity"

    var icon: String {
        switch self {
        case .custom: return "hand.draw"
        case .hostApp: return "rectangle.3.group"
        case .activity: return "bolt.circle"
        }
    }
}
