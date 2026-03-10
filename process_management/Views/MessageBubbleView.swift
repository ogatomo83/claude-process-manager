import SwiftUI

struct MessageBubbleView: View {
    let message: ConversationMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            switch message.role {
            case .user:
                userBubble
            case .assistant:
                assistantBubble
            case .tool:
                toolBubble
            case .system:
                systemBubble
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var userBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 60)
            Text(message.content)
                .font(.body)
                .padding(10)
                .background(Color.blue.opacity(0.15))
                .cornerRadius(12)
                .textSelection(.enabled)
        }
    }

    private var assistantBubble: some View {
        HStack(alignment: .top) {
            Image(systemName: "sparkle")
                .font(.caption)
                .foregroundStyle(.purple)
                .padding(.top, 4)

            Text(message.content)
                .font(.body)
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(12)
                .textSelection(.enabled)

            Spacer(minLength: 60)
        }
    }

    private var toolBubble: some View {
        HStack(alignment: .top) {
            Image(systemName: toolIcon)
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(width: 16)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.toolName ?? "tool")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)

                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.orange.opacity(0.06))
            .cornerRadius(8)

            Spacer(minLength: 60)
        }
    }

    private var systemBubble: some View {
        HStack {
            Text(message.content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private var toolIcon: String {
        switch message.toolName {
        case "Bash": return "terminal"
        case "Read": return "doc"
        case "Write": return "doc.badge.plus"
        case "Edit": return "pencil"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Task": return "arrow.triangle.branch"
        default: return "wrench"
        }
    }
}
