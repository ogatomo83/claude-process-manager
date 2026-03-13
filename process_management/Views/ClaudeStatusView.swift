import SwiftUI

struct ClaudeStatusView: View {
    let activity: ClaudeActivity
    let cpuPercent: Double

    // Animation states
    @State private var coreScale: CGFloat = 1.0
    @State private var coreOpacity: Double = 0.8
    @State private var ringRotation: Double = 0
    @State private var ring2Rotation: Double = 0
    @State private var particleOffset: CGFloat = 0
    @State private var pulseScale: CGFloat = 1.0

    private var coreColor: Color { activity.color }

    private var glowColor: Color {
        coreColor.opacity(0.3)
    }

    private var animationSpeed: Double {
        switch activity {
        case .thinking: return 1.2
        case .toolRunning: return 0.8
        case .responding: return 1.5
        case .waitingPermission: return 2.0
        case .compacting: return 1.0
        case .idle: return 3.0
        }
    }

    var body: some View {
        ZStack {
            // Background glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [glowColor, .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .scaleEffect(pulseScale)

            // Outer ring
            orbitRing(radius: 40, dotCount: 8, dotSize: 3, rotation: ringRotation, color: coreColor.opacity(0.4))

            // Inner ring (counter-rotating)
            orbitRing(radius: 26, dotCount: 5, dotSize: 4, rotation: ring2Rotation, color: coreColor.opacity(0.6))

            // Core orb
            ZStack {
                // Soft glow layer
                Circle()
                    .fill(coreColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .blur(radius: 6)

                // Main core
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [coreColor.opacity(0.9), coreColor.opacity(0.5)],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 20
                        )
                    )
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .offset(x: -3, y: -3)
                    )
            }
            .scaleEffect(coreScale)
            .opacity(coreOpacity)

            // Activity-specific particles
            if activity == .thinking || activity == .toolRunning || activity == .compacting {
                floatingParticles(color: coreColor)
            }
        }
        .frame(width: 120, height: 120)
        .onAppear { startAnimations() }
        .onChange(of: activity) { _, _ in startAnimations() }
    }

    // MARK: - Components

    private func orbitRing(radius: CGFloat, dotCount: Int, dotSize: CGFloat, rotation: Double, color: Color) -> some View {
        ZStack {
            ForEach(0..<dotCount, id: \.self) { i in
                let angle = (Double(i) / Double(dotCount)) * 360
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .offset(x: radius * cos(Angle(degrees: angle).radians),
                            y: radius * sin(Angle(degrees: angle).radians))
            }
        }
        .rotationEffect(.degrees(rotation))
    }

    private func floatingParticles(color: Color) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color.opacity(0.5))
                    .frame(width: 3, height: 3)
                    .offset(
                        x: CGFloat.random(in: -30...30) + particleOffset * CGFloat(i - 1),
                        y: -20 - particleOffset * CGFloat(i + 1)
                    )
                    .opacity(Double(3 - i) / 4.0)
            }
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        // Reset all animations to prevent accumulation
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            coreScale = 1.0
            coreOpacity = 0.8
            ringRotation = 0
            ring2Rotation = 0
            pulseScale = 1.0
            particleOffset = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Core breathing
            withAnimation(.easeInOut(duration: animationSpeed).repeatForever(autoreverses: true)) {
                coreScale = activity == .idle ? 1.05 : 1.2
                coreOpacity = activity == .idle ? 0.7 : 1.0
            }

            // Ring rotation
            withAnimation(.linear(duration: animationSpeed * 4).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }

            // Counter-rotation
            withAnimation(.linear(duration: animationSpeed * 3).repeatForever(autoreverses: false)) {
                ring2Rotation = -360
            }

            // Pulse
            withAnimation(.easeInOut(duration: animationSpeed * 1.5).repeatForever(autoreverses: true)) {
                pulseScale = activity == .idle ? 1.02 : 1.15
            }

            // Particle float
            if activity == .thinking || activity == .toolRunning {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    particleOffset = 8
                }
            }
        }
    }
}
