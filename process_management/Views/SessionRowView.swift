import SwiftUI

struct SessionRowView: View {
    let session: ClaudeSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                // Project name
                Text(session.projectName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                // Host app + elapsed
                HStack(spacing: 6) {
                    Image(systemName: hostAppIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(session.hostApp.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(session.elapsedTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // CPU + Memory
                HStack(spacing: 8) {
                    Label(String(format: "%.1f%%", session.cpuPercent), systemImage: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label(String(format: "%.0f MB", session.memoryMB), systemImage: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
    }

    private var statusColor: Color {
        switch session.status {
        case .active: return .green
        case .idle: return .yellow
        case .stale: return .gray
        }
    }

    private var hostAppIcon: String {
        switch session.hostApp {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .nvim: return "terminal"
        case .terminal: return "terminal"
        case .unknown: return "questionmark.circle"
        }
    }
}
