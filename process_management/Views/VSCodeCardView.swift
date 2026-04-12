import SwiftUI

struct VSCodeCardView: View {
    let window: VSCodeWindow
    let isSelected: Bool

    @State private var appear: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // "Claude なし" バナー
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 6, height: 6)

                Text("Claude なし")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.gray)

                Spacer()

                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.1))

            // Main content
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    // Static gray orb
                    ZStack {
                        Circle()
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 44, height: 44)
                            .blur(radius: 8)

                        Circle()
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            .frame(width: 36, height: 36)

                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.blue.opacity(0.6), Color.blue.opacity(0.2)],
                                    center: .topLeading, startRadius: 0, endRadius: 16
                                )
                            )
                            .frame(width: 24, height: 24)
                            .shadow(color: Color.blue.opacity(0.3), radius: 4)

                        Circle()
                            .fill(.white.opacity(0.25))
                            .frame(width: 7, height: 7)
                            .offset(x: -3, y: -4)

                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(width: 44, height: 44)

                    // Project info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(window.projectName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 9))
                            Text("VSCode")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.4))
                    }
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(width: 240)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(
            color: isSelected ? Color.blue.opacity(0.3) : .black.opacity(0.3),
            radius: isSelected ? 20 : 10,
            y: isSelected ? 8 : 4
        )
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 30)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appear = true }
        }
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(isSelected ? 0.08 : 0.02), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.gray.opacity(isSelected ? 0.4 : 0.12),
                            Color.gray.opacity(isSelected ? 0.1 : 0.03)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
    }
}
