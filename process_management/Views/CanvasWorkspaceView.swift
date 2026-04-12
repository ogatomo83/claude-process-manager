import SwiftUI
import Combine

struct CanvasWorkspaceView: View {
    @ObservedObject var monitor: ProcessMonitor
    let windowSwitcher: WindowSwitcher

    @StateObject private var launcher = ProjectLauncher()

    // Canvas state
    @State private var canvasOffset: CGSize = .zero
    @State private var canvasScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var cardPositions: [Int32: CGPoint] = [:]
    @State private var selectedPID: Int32? = nil
    @State private var showCommandPalette: Bool = false

    // Drag state (canvas pan)
    @State private var dragOffset: CGSize = .zero

    // View size for zoom center calculation
    @State private var viewSize: CGSize = .zero
    @State private var scrollMonitor: Any? = nil

    @FocusState private var isCanvasFocused: Bool

    private var visibleSessions: [ClaudeSession] {
        // Sort by projectName so j/k navigation follows a stable, intuitive order.
        monitor.sessions.sorted { a, b in
            let cmp = a.projectName.localizedCaseInsensitiveCompare(b.projectName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.id < b.id
        }
    }

    private var sortedVSCodeWindows: [VSCodeWindow] {
        monitor.vscodeWindows.sorted { a, b in
            let cmp = a.projectName.localizedCaseInsensitiveCompare(b.projectName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.id < b.id
        }
    }

    private var sortedNvimSessions: [NvimSession] {
        monitor.nvimSessions.sorted { a, b in
            let cmp = a.projectName.localizedCaseInsensitiveCompare(b.projectName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.id < b.id
        }
    }

    var body: some View {
        ZStack {
            canvasBackground

            canvasContent

            VStack {
                floatingToolbar
                Spacer()
            }

            // Command palette overlay
            if showCommandPalette {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) { showCommandPalette = false }
                    }
                VStack {
                    CommandPaletteView(launcher: launcher, isVisible: $showCommandPalette)
                        .padding(.top, 80)
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in viewSize = newSize }
            }
        )
        .focusable()
        .focused($isCanvasFocused)
        .onKeyPress { press in
            let kb = KeyBindingStore.shared

            // Escape closes command palette
            if showCommandPalette && press.key == .escape {
                withAnimation(.spring(response: 0.3)) { showCommandPalette = false }
                return .handled
            }

            // Command palette shortcut
            if kb.matches(.commandPalette, key: press.key, modifiers: press.modifiers) {
                launcher.scan(activeSessions: monitor.sessions)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showCommandPalette.toggle()
                }
                return .handled
            }

            // Disable session navigation while command palette is open
            guard !showCommandPalette else { return .ignored }

            if kb.matches(.nextSession, key: press.key, modifiers: press.modifiers) {
                selectNextSession()
                return .handled
            } else if kb.matches(.prevSession, key: press.key, modifiers: press.modifiers) {
                selectPrevSession()
                return .handled
            } else if kb.matches(.activateSession, key: press.key, modifiers: press.modifiers) {
                openSelectedSession()
                return .handled
            } else if kb.matches(.nextCluster, key: press.key, modifiers: press.modifiers) {
                DispatchQueue.main.async { selectNextCluster() }
                return .handled
            } else if kb.matches(.prevCluster, key: press.key, modifiers: press.modifiers) {
                DispatchQueue.main.async { selectPrevCluster() }
                return .handled
            }
            return .ignored
        }
        .onAppear {
            monitor.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                autoLayoutAllCards()
            }
            installScrollMonitor()
            isCanvasFocused = true
        }
        .onDisappear {
            monitor.stop()
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
        .onChange(of: monitor.sessions.count) { _, _ in
            cleanupStaleCardPositions()
            autoLayoutNewCards()
        }
        .onChange(of: monitor.vscodeWindows.count) { _, _ in
            autoLayoutNewCards()
        }
        .onChange(of: monitor.nvimSessions.count) { _, _ in
            cleanupStaleCardPositions()
            autoLayoutNewCards()
        }
        .onChange(of: monitor.selectedCluster) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    autoLayoutAllCards()
                }
            }
        }
    }

    private func installScrollMonitor() {
        if let existing = scrollMonitor {
            NSEvent.removeMonitor(existing)
            scrollMonitor = nil
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return nil }

            let oldScale = canvasScale
            let newScale = max(0.3, min(2.5, oldScale + delta * 0.03))
            let ratio = newScale / oldScale

            // Zoom around the center of the view
            let cx = viewSize.width / 2
            let cy = viewSize.height / 2
            let newOffsetW = canvasOffset.width * ratio + cx * (1 - ratio)
            let newOffsetH = canvasOffset.height * ratio + cy * (1 - ratio)

            canvasScale = newScale
            baseScale = newScale
            canvasOffset = CGSize(width: newOffsetW, height: newOffsetH)

            return nil // consume the event
        }
    }

    // MARK: - Session Navigation

    private func selectNextSession() {
        let ids = allCardIDs
        guard !ids.isEmpty else { return }
        if let current = selectedPID,
           let idx = ids.firstIndex(of: current) {
            let next = (idx + 1) % ids.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedPID = ids[next]
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedPID = ids.first
            }
        }
    }

    private func selectPrevSession() {
        let ids = allCardIDs
        guard !ids.isEmpty else { return }
        if let current = selectedPID,
           let idx = ids.firstIndex(of: current) {
            let prev = (idx - 1 + ids.count) % ids.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedPID = ids[prev]
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedPID = ids.last
            }
        }
    }

    private func switchCluster(offset: Int) {
        let clusters = monitor.discoveredClusters
        guard clusters.count > 1, let current = monitor.selectedCluster,
              let idx = clusters.firstIndex(of: current) else { return }
        let target = clusters[(idx + offset + clusters.count) % clusters.count]
        monitor.selectedCluster = target
        selectedPID = nil
        monitor.refresh()
    }

    private func selectNextCluster() { switchCluster(offset: 1) }
    private func selectPrevCluster() { switchCluster(offset: -1) }

    private func openSelectedSession() {
        guard let pid = selectedPID else { return }
        if isNvimCluster {
            if let nvim = monitor.nvimSessions.first(where: { $0.id == pid }) {
                windowSwitcher.activate(nvim: nvim)
                GlobalHotkeyService.shared.hideWindow(restorePreviousApp: false)
            }
            return
        }
        if let session = visibleSessions.first(where: { $0.id == pid }) {
            windowSwitcher.activate(session: session)
            GlobalHotkeyService.shared.hideWindow(restorePreviousApp: false)
        }
    }

    // MARK: - Background

    private var canvasBackground: some View {
        Canvas { context, size in
            let bgRect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(bgRect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.06, green: 0.06, blue: 0.12),
                        Color(red: 0.08, green: 0.05, blue: 0.15),
                        Color(red: 0.04, green: 0.04, blue: 0.10),
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            let spacing: CGFloat = 40 * canvasScale
            guard spacing > 5 else { return }
            let offsetX = canvasOffset.width.truncatingRemainder(dividingBy: spacing)
            let offsetY = canvasOffset.height.truncatingRemainder(dividingBy: spacing)

            for x in stride(from: offsetX, through: size.width, by: spacing) {
                for y in stride(from: offsetY, through: size.height, by: spacing) {
                    let dot = Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    context.fill(dot, with: .color(.white.opacity(0.08)))
                }
            }
        }
        .ignoresSafeArea()
        .gesture(canvasPanGesture)
        .gesture(canvasPinchGesture)
    }

    // MARK: - Canvas Content

    private var isVSCodeWindowsCluster: Bool {
        monitor.selectedCluster == .vscodeWindows
    }

    private var isNvimCluster: Bool {
        monitor.selectedCluster == .nvim
    }

    private var canvasContent: some View {
        ZStack {
            // Cluster label
            if let cluster = monitor.selectedCluster {
                let count: Int = {
                    switch cluster {
                    case .vscodeWindows: return monitor.vscodeWindows.count
                    case .nvim: return monitor.nvimSessions.count
                    default: return visibleSessions.count
                    }
                }()
                if count > 0 {
                    clusterLabel(cluster: cluster, count: count)
                }
            }

            // Session cards (hostApp clusters)
            if !isVSCodeWindowsCluster && !isNvimCluster {
                ForEach(visibleSessions) { session in
                    cardView(session: session)
                }
            }

            // VSCode window cards (vscodeWindows cluster)
            if isVSCodeWindowsCluster {
                ForEach(monitor.vscodeWindows) { window in
                    vscodeCardView(window: window)
                }
            }

            // Neovim session cards (nvim cluster)
            if isNvimCluster {
                ForEach(monitor.nvimSessions) { nvim in
                    nvimCardView(nvim: nvim)
                }
            }
        }
    }

    private func clusterLabel(cluster: ClusterKind, count: Int) -> some View {
        let center = layoutCenter
        let metrics = gridMetrics(count: count)
        let labelY = center.y - metrics.totalHeight / 2 - 40
        return HStack(spacing: 6) {
            Image(systemName: cluster.icon)
                .font(.system(size: 11))
            Text(cluster.label)
                .font(.system(size: 12, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .scaleEffect(canvasScale)
        .position(
            x: center.x * canvasScale + canvasOffset.width,
            y: labelY * canvasScale + canvasOffset.height
        )
    }

    private func cardView(session: ClaudeSession) -> some View {
        let pos = cardPositions[session.id] ?? CGPoint(x: 400, y: 300)
        return SessionCardView(
            session: session,
            isSelected: selectedPID == session.id
        )
        .scaleEffect(canvasScale)
        .position(
            x: pos.x * canvasScale + canvasOffset.width,
            y: pos.y * canvasScale + canvasOffset.height
        )
    }

    private func vscodeCardView(window: VSCodeWindow) -> some View {
        let pos = cardPositions[window.id] ?? CGPoint(x: 400, y: 300)
        return VSCodeCardView(
            window: window,
            isSelected: selectedPID == window.id
        )
        .scaleEffect(canvasScale)
        .position(
            x: pos.x * canvasScale + canvasOffset.width,
            y: pos.y * canvasScale + canvasOffset.height
        )
    }

    private func nvimCardView(nvim: NvimSession) -> some View {
        let pos = cardPositions[nvim.id] ?? CGPoint(x: 400, y: 300)
        return NvimSessionCardView(
            session: nvim,
            isSelected: selectedPID == nvim.id
        )
        .scaleEffect(canvasScale)
        .position(
            x: pos.x * canvasScale + canvasOffset.width,
            y: pos.y * canvasScale + canvasOffset.height
        )
    }

    // MARK: - Floating Toolbar

    private var floatingToolbar: some View {
        HStack(spacing: 12) {
            Text("Claude セッション")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                let count: Int = {
                    if isVSCodeWindowsCluster { return monitor.vscodeWindows.count }
                    if isNvimCluster { return monitor.nvimSessions.count }
                    return visibleSessions.count
                }()
                Text("\(count) 件アクティブ")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }

            // Cluster selector (radio-button: one active at a time)
            ForEach(monitor.discoveredClusters, id: \.self) { cluster in
                let isActive = monitor.selectedCluster == cluster
                let hasSession: Bool = {
                    switch cluster {
                    case .hostApp(let app): return monitor.activeHostApps.contains(app)
                    case .vscodeWindows: return !monitor.vscodeWindows.isEmpty
                    case .nvim: return !monitor.nvimSessions.isEmpty
                    }
                }()
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        monitor.selectedCluster = cluster
                        selectedPID = nil
                        monitor.refresh()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: cluster.icon)
                        Text(cluster.label)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(isActive ? .cyan : hasSession ? .white.opacity(0.3) : .white.opacity(0.15))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isActive ? .cyan.opacity(0.1) : .white.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16).overlay(Color.white.opacity(0.15))

            // Zoom controls
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        canvasScale = max(0.3, canvasScale - 0.15)
                        baseScale = canvasScale
                    }
                } label: {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.white.opacity(0.6))
                }.buttonStyle(.plain)

                Text("\(Int(canvasScale * 100))%")
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).frame(width: 40)

                Button {
                    withAnimation(.spring(response: 0.3)) {
                        canvasScale = min(2.0, canvasScale + 0.15)
                        baseScale = canvasScale
                    }
                } label: {
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.white.opacity(0.6))
                }.buttonStyle(.plain)
            }

            Button {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    canvasOffset = .zero; canvasScale = 1.0; baseScale = 1.0
                }
            } label: {
                Image(systemName: "arrow.counterclockwise").foregroundStyle(.white.opacity(0.6))
            }.buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { autoLayoutAllCards() }
            } label: {
                Image(systemName: "rectangle.3.group").foregroundStyle(.white.opacity(0.6))
            }.buttonStyle(.plain)

            // Command palette
            Button {
                launcher.scan(activeSessions: monitor.sessions)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showCommandPalette.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                    Text("/")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Gestures

    private var canvasPanGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                canvasOffset = CGSize(
                    width: canvasOffset.width + value.translation.width - dragOffset.width,
                    height: canvasOffset.height + value.translation.height - dragOffset.height
                )
                dragOffset = value.translation
            }
            .onEnded { _ in dragOffset = .zero }
    }

    private var canvasPinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                canvasScale = max(0.3, min(2.5, baseScale * value.magnification))
            }
            .onEnded { _ in baseScale = canvasScale }
    }

    // MARK: - Cleanup

    /// Remove cardPositions entries for dead PIDs
    private func cleanupStaleCardPositions() {
        let aliveIDs = Set(monitor.sessions.map { $0.id })
        let vscodeIDs = Set(monitor.vscodeWindows.map { $0.id })
        let nvimIDs = Set(monitor.nvimSessions.map { $0.id })
        let validIDs = aliveIDs.union(vscodeIDs).union(nvimIDs)
        cardPositions = cardPositions.filter { validIDs.contains($0.key) }
    }

    // MARK: - Layout

    private var layoutCenter: CGPoint {
        CGPoint(
            x: max(viewSize.width, 800) / 2,
            y: max(viewSize.height, 600) / 2
        )
    }

    private func autoLayoutNewCards() {
        let ids = allCardIDs
        let hasNew = ids.contains { cardPositions[$0] == nil }
        guard hasNew else { return }

        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            autoLayoutAllCards()
        }
    }

    /// Cards in the order used by j/k navigation and auto-layout.
    /// Sorted by projectName so the visual grid matches navigation order.
    private var allCardIDs: [Int32] {
        if isVSCodeWindowsCluster {
            return sortedVSCodeWindows.map { $0.id }
        }
        if isNvimCluster {
            return sortedNvimSessions.map { $0.id }
        }
        return visibleSessions.map { $0.id }
    }

    /// Metrics describing the grid layout for a given card count.
    private struct GridMetrics {
        let cols: Int
        let rows: Int
        let slotW: CGFloat
        let slotH: CGFloat
        var totalWidth: CGFloat { slotW * CGFloat(cols) }
        var totalHeight: CGFloat { slotH * CGFloat(rows) }
    }

    private func gridMetrics(count: Int) -> GridMetrics {
        let slotW: CGFloat = 280
        let slotH: CGFloat = 200
        let usableWidth = max(viewSize.width - 80, 800)
        let maxCols = max(1, Int(usableWidth / slotW))
        let safeCount = max(count, 1)
        let cols = min(maxCols, safeCount)
        let rows = (safeCount + cols - 1) / cols
        return GridMetrics(cols: cols, rows: rows, slotW: slotW, slotH: slotH)
    }

    /// Grid layout: cards placed in reading order (left→right, top→bottom).
    /// Order matches `allCardIDs` so j/k navigation feels natural.
    private func autoLayoutAllCards() {
        let ids = allCardIDs
        guard !ids.isEmpty else { return }

        let metrics = gridMetrics(count: ids.count)
        let center = layoutCenter
        let startX = center.x - metrics.totalWidth / 2 + metrics.slotW / 2
        let startY = center.y - metrics.totalHeight / 2 + metrics.slotH / 2

        for (i, id) in ids.enumerated() {
            let row = i / metrics.cols
            let col = i % metrics.cols
            cardPositions[id] = CGPoint(
                x: startX + CGFloat(col) * metrics.slotW,
                y: startY + CGFloat(row) * metrics.slotH
            )
        }
    }
}
