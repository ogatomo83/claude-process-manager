import SwiftUI

struct NvimSessionCardView: View {
    let session: NvimSession
    let isSelected: Bool

    @State private var appear: Bool = false

    private var accentColor: Color { .green }

    private var hostIcon: String { session.hostApp.icon }

    private var claudeCount: Int { session.claudeSessions.count }

    var body: some View {
        VStack(spacing: 0) {
            // Banner
            HStack(spacing: 6) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: accentColor, radius: 3)

                Text("Neovim")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentColor)

                if claudeCount > 0 {
                    Text("Claude +\(claudeCount)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(accentColor.opacity(0.25))
                        )
                }

                Spacer()

                Text(session.elapsedTime)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))

                Image(systemName: "keyboard")
                    .font(.system(size: 10))
                    .foregroundStyle(accentColor.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.1))

            // Main content
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    // Static orb
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(0.2))
                            .frame(width: 44, height: 44)
                            .blur(radius: 8)

                        Circle()
                            .stroke(accentColor.opacity(0.25), lineWidth: 1)
                            .frame(width: 36, height: 36)

                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [accentColor.opacity(0.85), accentColor.opacity(0.25)],
                                    center: .topLeading, startRadius: 0, endRadius: 16
                                )
                            )
                            .frame(width: 24, height: 24)
                            .shadow(color: accentColor.opacity(0.5), radius: 5)

                        Circle()
                            .fill(.white.opacity(0.3))
                            .frame(width: 7, height: 7)
                            .offset(x: -3, y: -4)

                        Image(systemName: "keyboard")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .frame(width: 44, height: 44)

                    // Project info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.projectName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 4) {
                            Image(systemName: hostIcon)
                                .font(.system(size: 9))
                            Text(session.hostApp.rawValue)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.4))
                    }
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Resource bars
                HStack(spacing: 12) {
                    resourceBar(
                        icon: "cpu",
                        value: session.cpuPercent, max: 100,
                        label: String(format: "%.0f%%", session.cpuPercent),
                        color: session.cpuPercent > 50 ? .red : session.cpuPercent > 10 ? .orange : .cyan
                    )
                    resourceBar(
                        icon: "memorychip",
                        value: session.memoryMB, max: 1024,
                        label: String(format: "%.0fMB", session.memoryMB),
                        color: session.memoryMB > 500 ? .orange : .blue
                    )
                }

                // Nested Claude badges (only when there are sessions)
                if !session.claudeSessions.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    claudeBadgeRow
                }
            }
            .padding(12)
        }
        .frame(width: 260)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(
            color: isSelected ? accentColor.opacity(0.4) : .black.opacity(0.3),
            radius: isSelected ? 22 : 10,
            y: isSelected ? 8 : 4
        )
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 30)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appear = true }
        }
    }

    // MARK: - Nested Claude badges

    private var claudeBadgeRow: some View {
        HStack(spacing: 6) {
            ForEach(session.claudeSessions) { claude in
                HStack(spacing: 4) {
                    Circle()
                        .fill(claude.activity.color)
                        .frame(width: 5, height: 5)
                        .shadow(color: claude.activity.color, radius: 2)

                    Image(systemName: claude.activity.icon)
                        .font(.system(size: 8))
                        .foregroundStyle(claude.activity.color.opacity(0.9))

                    Text(claude.projectName)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(claude.activity.color.opacity(0.12))
                        .overlay(
                            Capsule().stroke(claude.activity.color.opacity(0.25), lineWidth: 0.5)
                        )
                )
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Background

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(isSelected ? 0.12 : 0.04), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(isSelected ? 0.6 : 0.15),
                            accentColor.opacity(isSelected ? 0.15 : 0.03)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
    }

    // MARK: - Resource bar

    private func resourceBar(icon: String, value: Double, max maxVal: Double, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color.opacity(0.8))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.06))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geo.size.width * min(value / maxVal, 1.0)), height: 4)
                        .shadow(color: color.opacity(0.5), radius: 2)
                }
            }
            .frame(height: 4)

            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 40, alignment: .trailing)
        }
    }
}
