import SwiftUI

struct SessionCardView: View {
    let session: ClaudeSession
    let isSelected: Bool
    let isHovered: Bool

    @State private var appear: Bool = false
    @State private var orbitAngle: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3
    @State private var particleY: CGFloat = 0
    @State private var tiltX: Double = 0
    @State private var tiltY: Double = 0

    private var activity: ClaudeActivity { session.activity }

    private var activityColor: Color { activity.color }

    private var hostColor: Color {
        switch session.hostApp {
        case .vscode: return .blue
        case .nvim: return .green
        case .terminal: return .orange
        case .unknown: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Activity banner at top
            activityBanner

            // Main content
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    // Animated orb
                    activityOrb

                    // Project info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.projectName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Image(systemName: hostIcon)
                                .font(.system(size: 9))
                            Text(session.hostApp.rawValue)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.4))
                    }

                    Spacer()

                    Text(session.elapsedTime)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
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
            }
            .padding(12)
        }
        .frame(width: 240)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(
            color: isSelected ? activityColor.opacity(0.4) : .black.opacity(0.3),
            radius: isSelected ? 24 : 10,
            y: isSelected ? 8 : 4
        )
        .rotation3DEffect(.degrees(isHovered ? tiltY : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(isHovered ? tiltX : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .scaleEffect(isHovered ? 1.06 : (isSelected ? 1.03 : 1.0))
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 30)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appear = true }
            startAnimations()
        }
        .onChange(of: activity) { _ in startAnimations() }
    }

    // MARK: - Activity Banner

    private var activityBanner: some View {
        HStack(spacing: 6) {
            // Pulsing dot
            Circle()
                .fill(activityColor)
                .frame(width: 6, height: 6)
                .shadow(color: activityColor, radius: 4)
                .scaleEffect(pulseScale)

            Text(activity.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(activityColor)

            Spacer()

            // Activity-specific icon
            Image(systemName: activityIcon)
                .font(.system(size: 10))
                .foregroundStyle(activityColor.opacity(0.8))
                .rotationEffect(.degrees(activity == .toolRunning ? orbitAngle : 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(activityColor.opacity(0.1))
    }

    // MARK: - Orb

    private var activityOrb: some View {
        ZStack {
            // Glow
            Circle()
                .fill(activityColor.opacity(glowOpacity))
                .frame(width: 44, height: 44)
                .blur(radius: 8)

            // Outer ring
            Circle()
                .stroke(activityColor.opacity(0.2), lineWidth: 1)
                .frame(width: 36, height: 36)

            // Core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [activityColor.opacity(0.9), activityColor.opacity(0.3)],
                        center: .topLeading, startRadius: 0, endRadius: 16
                    )
                )
                .frame(width: 24, height: 24)
                .shadow(color: activityColor.opacity(0.6), radius: 6)

            // Highlight
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 7, height: 7)
                .offset(x: -3, y: -4)

            // Orbit dots
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(activityColor.opacity(0.7))
                    .frame(width: 3, height: 3)
                    .offset(x: 18)
                    .rotationEffect(.degrees(orbitAngle + Double(i) * 120))
            }

            // Rising particles (thinking/toolRunning/compacting)
            if activity == .thinking || activity == .toolRunning || activity == .compacting {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(activityColor.opacity(Double(4 - i) / 6.0))
                        .frame(width: 2, height: 2)
                        .offset(
                            x: CGFloat([-6, 3, -2, 5][i]),
                            y: -14 - particleY * CGFloat(i + 1) / 2
                        )
                }
            }
        }
        .frame(width: 44, height: 44)
    }

    // MARK: - Background

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)

            // Activity-colored gradient overlay
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [activityColor.opacity(isSelected ? 0.12 : 0.04), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            // Border
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    LinearGradient(
                        colors: [
                            activityColor.opacity(isSelected ? 0.6 : 0.15),
                            activityColor.opacity(isSelected ? 0.15 : 0.03)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
    }

    // MARK: - Helpers

    private var activityIcon: String { activity.icon }

    private var hostIcon: String {
        switch session.hostApp {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .nvim: return "terminal"
        case .terminal: return "terminal"
        case .unknown: return "questionmark.circle"
        }
    }

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

    // MARK: - Animations

    private func startAnimations() {
        // Reset all animations to prevent accumulation
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            orbitAngle = 0
            pulseScale = 1.0
            glowOpacity = 0.3
            particleY = 0
            tiltX = 0
            tiltY = 0
        }

        let speed: Double = {
            switch activity {
            case .thinking: return 1.5
            case .toolRunning: return 1.0
            case .responding: return 2.0
            case .waitingPermission: return 2.5
            case .compacting: return 1.8
            case .idle: return 5.0
            }
        }()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.linear(duration: speed * 2).repeatForever(autoreverses: false)) {
                orbitAngle = 360
            }

            withAnimation(.easeInOut(duration: speed * 0.6).repeatForever(autoreverses: true)) {
                pulseScale = activity == .idle ? 1.0 : 1.5
                glowOpacity = activity == .idle ? 0.15 : 0.6
            }

            if activity == .thinking || activity == .toolRunning {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    particleY = 10
                }
            }

            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                tiltX = Double.random(in: -3...3)
                tiltY = Double.random(in: -2...2)
            }
        }
    }
}
