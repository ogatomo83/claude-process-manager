import SwiftUI

struct SessionListView: View {
    let sessions: [ClaudeSession]
    @Binding var selectedSession: ClaudeSession?
    let onSelect: (ClaudeSession) -> Void
    let onActivate: (ClaudeSession) -> Void

    private var groupedSessions: [(hostApp: HostApp, sessions: [ClaudeSession])] {
        let dict = Dictionary(grouping: sessions) { $0.hostApp }
        let order: [HostApp] = [.vscode, .iterm2, .terminal, .unknown]
        return order.compactMap { app in
            guard let group = dict[app], !group.isEmpty else { return nil }
            return (hostApp: app, sessions: group)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("セッション")
                    .font(.headline)
                Spacer()
                Text("\(sessions.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "moon.zzz")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Claude Code が起動していません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groupedSessions, id: \.hostApp) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    SessionRowView(
                                        session: session,
                                        isSelected: selectedSession?.id == session.id
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        onSelect(session)
                                        onActivate(session)
                                    }
                                    .onTapGesture(count: 1) {
                                        onSelect(session)
                                    }
                                }
                            } header: {
                                sectionHeader(group.hostApp, count: group.sessions.count)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func sectionHeader(_ app: HostApp, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: hostAppIcon(app))
                .font(.caption2)
            Text(app.rawValue)
                .font(.caption)
                .fontWeight(.semibold)
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func hostAppIcon(_ app: HostApp) -> String {
        app.icon
    }
}
