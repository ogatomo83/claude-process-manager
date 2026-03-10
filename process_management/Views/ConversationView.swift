import SwiftUI

struct ConversationView: View {
    let session: ClaudeSession?
    @ObservedObject var loader: ConversationLoader

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                // Header with status orb
                conversationHeader(session)
                Divider()

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(loader.messages) { message in
                                MessageBubbleView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: loader.messages.count) { _ in
                        if let last = loader.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                emptyState
            }
        }
    }

    private func conversationHeader(_ session: ClaudeSession) -> some View {
        HStack(spacing: 16) {
            // Animated status orb
            ClaudeStatusView(
                activity: loader.activity,
                cpuPercent: session.cpuPercent
            )
            .frame(width: 80, height: 80)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.projectName)
                    .font(.headline)
                Text(session.projectPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    // Activity label
                    Text(loader.activity.label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(activityColor)

                    // Process status badge
                    Text(session.status.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusBackground(session.status))
                        .cornerRadius(8)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var activityColor: Color {
        switch loader.activity {
        case .thinking: return .purple
        case .toolRunning: return .orange
        case .responding: return .green
        case .idle: return .secondary
        }
    }

    private func statusBackground(_ status: SessionStatus) -> Color {
        switch status {
        case .active: return .green.opacity(0.15)
        case .idle: return .yellow.opacity(0.15)
        case .stale: return .gray.opacity(0.15)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ClaudeStatusView(activity: .idle, cpuPercent: 0)
                .frame(width: 120, height: 120)
            Text("セッションを選択してください")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("ダブルクリックでウィンドウを切り替え")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
