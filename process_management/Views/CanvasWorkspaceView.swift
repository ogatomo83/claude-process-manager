import SwiftUI

struct CanvasWorkspaceView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var conversationLoader: ConversationLoader
    let windowSwitcher: WindowSwitcher

    @StateObject private var launcher = ProjectLauncher()

    // Canvas state
    @State private var canvasOffset: CGSize = .zero
    @State private var canvasScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var cardPositions: [Int32: CGPoint] = [:]
    @State private var selectedPID: Int32? = nil
    @State private var showDetail: Bool = false
    @State private var hoveredPID: Int32? = nil
    @State private var showProjectList: Bool = false

    // Drag state
    @State private var dragOffset: CGSize = .zero
    @State private var cardDragStart: [Int32: CGPoint] = [:]

    // Grouping state
    @State private var groups: [CanvasGroup] = []
    @State private var groupingMode: GroupingMode = .custom
    @State private var isLassoMode: Bool = false
    @State private var lassoPoints: [CGPoint] = []
    @State private var selectedGroupID: UUID? = nil
    @State private var editingGroupID: UUID? = nil
    @State private var hoveredGroupID: UUID? = nil

    // Host app filter
    @State private var showAllHostApps: Bool = false

    // Group editor
    @State private var editingGroupName: String = ""
    @State private var newRulePathPrefix: String = ""

    // View size for zoom center calculation
    @State private var viewSize: CGSize = .zero
    @State private var scrollMonitor: Any? = nil

    // Animation
    @State private var energyPhase: Double = 0
    @State private var energyTimer: Timer?

    private var visibleSessions: [ClaudeSession] {
        if showAllHostApps {
            return monitor.sessions
        }
        return monitor.sessions.filter { $0.hostApp == .vscode }
    }

    var body: some View {
        ZStack {
            canvasBackground

            canvasContent

            // Lasso overlay
            if isLassoMode {
                lassoOverlay
            }

            VStack {
                floatingToolbar
                Spacer()
            }

            // Detail panel
            if showDetail, let pid = selectedPID,
               let session = monitor.sessions.first(where: { $0.id == pid }) {
                detailPanel(session: session)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // Group editor
            if let editID = editingGroupID,
               let idx = groups.firstIndex(where: { $0.id == editID }) {
                groupEditor(group: groups[idx])
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .onAppear { editingGroupName = groups[idx].name }
            }

            // Project launcher overlay
            if showProjectList {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) { showProjectList = false }
                    }
                ProjectListView(launcher: launcher, isVisible: $showProjectList)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { newSize in viewSize = newSize }
            }
        )
        .onAppear {
            monitor.start()
            startEnergyAnimation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                autoLayoutAllCards()
            }
            installScrollMonitor()
        }
        .onDisappear {
            monitor.stop()
            conversationLoader.stop()
            energyTimer?.invalidate()
            energyTimer = nil
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
        .onChange(of: monitor.sessions.count) { _ in
            autoLayoutNewCards()
            if groupingMode != .custom {
                applyAutoGrouping()
            }
        }
        .onChange(of: monitor.vscodeWindows.count) { _ in
            autoLayoutNewCards()
            if groupingMode == .vscode {
                applyAutoGrouping()
            }
        }
        .onReceive(monitor.$sessions) { _ in
            evaluateGroupRules()
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
        .gesture(isLassoMode ? nil : canvasPanGesture)
        .gesture(canvasPinchGesture)
        .simultaneousGesture(isLassoMode ? lassoGesture : nil)
        .onTapGesture(count: 2) {
            if !isLassoMode {
                // Double-tap empty canvas to create an empty group at that spot
                let newGroup = CanvasGroup.randomPreset(position: CGPoint(x: 400, y: 300))
                withAnimation(.spring(response: 0.5)) {
                    groups.append(newGroup)
                    editingGroupID = newGroup.id
                }
            }
        }
    }

    // MARK: - Canvas Content

    private var canvasContent: some View {
        ZStack {
            // Group visuals (behind cards)
            ForEach(groups) { group in
                groupVisual(group: group)
            }

            // Energy connections between grouped cards
            energyConnections

            // Session cards
            ForEach(visibleSessions) { session in
                cardView(session: session)
            }

            // VSCode-only window cards
            if monitor.detectVSCode {
                ForEach(monitor.vscodeWindows) { window in
                    vscodeCardView(window: window)
                }
            }
        }
    }

    private func cardView(session: ClaudeSession) -> some View {
        let pos = cardPositions[session.id] ?? CGPoint(x: 400, y: 300)
        return SessionCardView(
            session: session,
            isSelected: selectedPID == session.id,
            isHovered: hoveredPID == session.id
        )
        .position(
            x: pos.x * canvasScale + canvasOffset.width,
            y: pos.y * canvasScale + canvasOffset.height
        )
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredPID = isHovered ? session.id : nil
            }
        }
        .onTapGesture(count: 2) {
            windowSwitcher.activate(session: session)
        }
        .onTapGesture(count: 1) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                if selectedPID == session.id {
                    showDetail.toggle()
                } else {
                    selectedPID = session.id
                    showDetail = true
                    if let path = session.jsonlPath {
                        conversationLoader.load(jsonlPath: path)
                    }
                }
            }
        }
        .gesture(makeCardDragGesture(pid: session.id))
        .contextMenu {
            // Add to existing group
            if !groups.isEmpty {
                Menu("Add to Group") {
                    ForEach(groups) { group in
                        Button {
                            if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                                withAnimation(.spring(response: 0.3)) {
                                    groups[idx].memberPIDs.insert(session.id)
                                }
                            }
                        } label: {
                            Label(group.name, systemImage: "folder")
                        }
                    }
                }
            }

            // New group with this card
            Button {
                var newGroup = CanvasGroup.randomPreset(
                    memberPIDs: [session.id],
                    position: cardPositions[session.id] ?? .zero
                )
                newGroup.name = session.projectName
                withAnimation(.spring(response: 0.5)) {
                    groups.append(newGroup)
                    editingGroupID = newGroup.id
                    editingGroupName = newGroup.name
                }
            } label: {
                Label("New Group with This Card", systemImage: "plus.rectangle.on.folder")
            }

            // Remove from group
            let containingGroups = groups.filter { $0.memberPIDs.contains(session.id) }
            if !containingGroups.isEmpty {
                Divider()
                ForEach(containingGroups) { group in
                    Button(role: .destructive) {
                        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                            withAnimation(.spring(response: 0.3)) {
                                groups[idx].memberPIDs.remove(session.id)
                            }
                            // Clean up empty groups
                            groups.removeAll { $0.memberPIDs.isEmpty && $0.rules.isEmpty }
                        }
                    } label: {
                        Label("Remove from \(group.name)", systemImage: "minus.circle")
                    }
                }
            }
        }
    }

    private func vscodeCardView(window: VSCodeWindow) -> some View {
        let pos = cardPositions[window.id] ?? CGPoint(x: 400, y: 300)
        return VSCodeCardView(
            window: window,
            isSelected: selectedPID == window.id,
            isHovered: hoveredPID == window.id
        )
        .position(
            x: pos.x * canvasScale + canvasOffset.width,
            y: pos.y * canvasScale + canvasOffset.height
        )
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredPID = isHovered ? window.id : nil
            }
        }
        .onTapGesture(count: 2) {
            windowSwitcher.activateVSCodeWindow(projectName: window.projectName)
        }
        .onTapGesture(count: 1) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                if selectedPID == window.id {
                    selectedPID = nil
                } else {
                    selectedPID = window.id
                    showDetail = false
                }
            }
        }
        .gesture(makeCardDragGesture(pid: window.id))
        .contextMenu {
            // Launch Claude in this VSCode window
            Button {
                let launcher = ProjectLauncher()
                let entry = ProjectEntry(
                    id: window.windowTitle,
                    name: window.projectName,
                    parentDir: "",
                    path: "",
                    hasClaudeSession: false,
                    isVSCodeOpen: true
                )
                launcher.launch(project: entry)
            } label: {
                Label("Launch Claude", systemImage: "play.circle")
            }

            // Add to existing group
            if !groups.isEmpty {
                Menu("Add to Group") {
                    ForEach(groups) { group in
                        Button {
                            if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                                withAnimation(.spring(response: 0.3)) {
                                    groups[idx].memberPIDs.insert(window.id)
                                }
                            }
                        } label: {
                            Label(group.name, systemImage: "folder")
                        }
                    }
                }
            }

            // New group with this card
            Button {
                var newGroup = CanvasGroup.randomPreset(
                    memberPIDs: [window.id],
                    position: cardPositions[window.id] ?? .zero
                )
                newGroup.name = window.projectName
                withAnimation(.spring(response: 0.5)) {
                    groups.append(newGroup)
                    editingGroupID = newGroup.id
                    editingGroupName = newGroup.name
                }
            } label: {
                Label("New Group with This Card", systemImage: "plus.rectangle.on.folder")
            }
        }
    }

    // MARK: - Group Visuals

    @ViewBuilder
    private func groupVisual(group: CanvasGroup) -> some View {
        let memberPositions = group.memberPIDs.compactMap { cardPositions[$0] }
        if !memberPositions.isEmpty {
            let visual: AnyView = {
                switch group.style {
                case .nebula:
                    return AnyView(nebulaGroup(group: group, positions: memberPositions))
                case .constellation:
                    return AnyView(constellationGroup(group: group, positions: memberPositions))
                case .aurora:
                    return AnyView(auroraGroup(group: group, positions: memberPositions))
                case .circuit:
                    return AnyView(circuitGroup(group: group, positions: memberPositions))
                }
            }()

            visual
                .contextMenu {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            editingGroupID = group.id
                            editingGroupName = group.name
                        }
                    } label: {
                        Label("Edit Group", systemImage: "pencil")
                    }

                    // Add member - show unassigned sessions
                    let unassignedSessions = visibleSessions.filter { session in
                        !group.memberPIDs.contains(session.id)
                    }
                    if !unassignedSessions.isEmpty {
                        Menu("Add Member") {
                            ForEach(unassignedSessions) { session in
                                Button {
                                    if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                                        withAnimation(.spring(response: 0.3)) {
                                            groups[idx].memberPIDs.insert(session.id)
                                        }
                                    }
                                } label: {
                                    Label(session.projectName, systemImage: "plus.circle")
                                }
                            }
                        }
                    }

                    // Remove member
                    let memberSessions = visibleSessions.filter { group.memberPIDs.contains($0.id) }
                    if !memberSessions.isEmpty {
                        Menu("Remove Member") {
                            ForEach(memberSessions) { session in
                                Button {
                                    if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                                        withAnimation(.spring(response: 0.3)) {
                                            groups[idx].memberPIDs.remove(session.id)
                                        }
                                        groups.removeAll { $0.memberPIDs.isEmpty && $0.rules.isEmpty }
                                    }
                                } label: {
                                    Label(session.projectName, systemImage: "minus.circle")
                                }
                            }
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        withAnimation(.spring(response: 0.3)) {
                            groups.removeAll { $0.id == group.id }
                        }
                    } label: {
                        Label("Dissolve Group", systemImage: "trash")
                    }
                }
        }
    }

    // MARK: Nebula Style
    private func nebulaGroup(group: CanvasGroup, positions: [CGPoint]) -> some View {
        let bounds = groupBounds(positions: positions, padding: 100)
        let center = canvasPoint(bounds.center)
        let w = bounds.size.width * canvasScale
        let h = bounds.size.height * canvasScale

        return ZStack {
            // Multiple overlapping blurred ellipses for nebula effect
            ForEach(0..<3, id: \.self) { i in
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                group.color.opacity(0.15 - Double(i) * 0.04),
                                group.color.opacity(0.05 - Double(i) * 0.01),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: max(w, h) / 2
                        )
                    )
                    .frame(
                        width: w + CGFloat(i) * 40,
                        height: h + CGFloat(i) * 30
                    )
                    .rotationEffect(.degrees(Double(i) * 15 + energyPhase * (i == 1 ? 0.3 : 0.1)))
                    .blur(radius: CGFloat(8 + i * 6))
            }

            // Inner glow ring
            Ellipse()
                .stroke(
                    group.color.opacity(0.12),
                    lineWidth: 1.5
                )
                .frame(width: w * 0.85, height: h * 0.85)
                .blur(radius: 2)

            // Group label
            groupLabel(group: group, position: CGPoint(x: center.x, y: center.y - h / 2 + 15))
        }
        .position(center)
        .allowsHitTesting(true)
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.3)) {
                editingGroupID = group.id
            }
        }
        .onHover { hover in
            hoveredGroupID = hover ? group.id : nil
        }
    }

    // MARK: Constellation Style
    private func constellationGroup(group: CanvasGroup, positions: [CGPoint]) -> some View {
        let bounds = groupBounds(positions: positions, padding: 80)
        let center = canvasPoint(bounds.center)
        let scaledPositions = positions.map { canvasPoint($0) }

        return ZStack {
            // Star field background
            Canvas { context, size in
                // Draw constellation lines
                if scaledPositions.count > 1 {
                    for i in 0..<scaledPositions.count {
                        for j in (i + 1)..<scaledPositions.count {
                            let from = CGPoint(
                                x: scaledPositions[i].x - center.x + size.width / 2,
                                y: scaledPositions[i].y - center.y + size.height / 2
                            )
                            let to = CGPoint(
                                x: scaledPositions[j].x - center.x + size.width / 2,
                                y: scaledPositions[j].y - center.y + size.height / 2
                            )
                            var path = Path()
                            path.move(to: from)
                            path.addLine(to: to)
                            context.stroke(
                                path,
                                with: .color(group.color.opacity(0.15)),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            )
                        }
                    }
                }

                // Draw star dots at each position
                for pos in scaledPositions {
                    let local = CGPoint(
                        x: pos.x - center.x + size.width / 2,
                        y: pos.y - center.y + size.height / 2
                    )
                    let starRect = CGRect(x: local.x - 3, y: local.y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: starRect), with: .color(group.color.opacity(0.5)))
                    let glowRect = CGRect(x: local.x - 8, y: local.y - 8, width: 16, height: 16)
                    context.fill(Path(ellipseIn: glowRect), with: .color(group.color.opacity(0.1)))
                }

                // Scatter small stars
                let seed = group.id.hashValue
                for i in 0..<20 {
                    let sx = CGFloat(((seed + i * 17) % Int(size.width)).magnitude)
                    let sy = CGFloat(((seed + i * 31) % Int(size.height)).magnitude)
                    let starSize: CGFloat = CGFloat(1 + (i % 3))
                    let rect = CGRect(x: sx, y: sy, width: starSize, height: starSize)
                    let brightness = (sin(energyPhase * 0.05 + Double(i)) + 1) / 2
                    context.fill(Path(ellipseIn: rect), with: .color(group.color.opacity(0.1 + brightness * 0.15)))
                }
            }
            .frame(width: bounds.size.width * canvasScale, height: bounds.size.height * canvasScale)

            groupLabel(group: group, position: CGPoint(
                x: center.x,
                y: center.y - bounds.size.height * canvasScale / 2 + 15
            ))
        }
        .position(center)
        .allowsHitTesting(true)
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.3)) { editingGroupID = group.id }
        }
        .onHover { hover in hoveredGroupID = hover ? group.id : nil }
    }

    // MARK: Aurora Style
    private func auroraGroup(group: CanvasGroup, positions: [CGPoint]) -> some View {
        let bounds = groupBounds(positions: positions, padding: 90)
        let center = canvasPoint(bounds.center)
        let w = bounds.size.width * canvasScale
        let h = bounds.size.height * canvasScale

        return ZStack {
            // Aurora waves
            ForEach(0..<4, id: \.self) { i in
                WaveShape(phase: energyPhase * 0.02 + Double(i) * 0.8, amplitude: 15 + Double(i) * 5)
                    .stroke(
                        group.color.opacity(0.08 + Double(3 - i) * 0.03),
                        lineWidth: 2
                    )
                    .frame(width: w, height: h * 0.6)
                    .offset(y: CGFloat(i - 2) * 20)
                    .blur(radius: CGFloat(2 + i))
            }

            // Soft glow underneath
            Ellipse()
                .fill(group.color.opacity(0.06))
                .frame(width: w * 0.9, height: h * 0.5)
                .blur(radius: 20)

            groupLabel(group: group, position: CGPoint(
                x: center.x,
                y: center.y - h / 2 + 15
            ))
        }
        .position(center)
        .allowsHitTesting(true)
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.3)) { editingGroupID = group.id }
        }
        .onHover { hover in hoveredGroupID = hover ? group.id : nil }
    }

    // MARK: Circuit Style
    private func circuitGroup(group: CanvasGroup, positions: [CGPoint]) -> some View {
        let bounds = groupBounds(positions: positions, padding: 160)
        let center = canvasPoint(bounds.center)
        let w = bounds.size.width * canvasScale
        let h = bounds.size.height * canvasScale
        let scaledPositions = positions.map { canvasPoint($0) }

        return ZStack {
            // Circuit board background
            RoundedRectangle(cornerRadius: 12)
                .fill(group.color.opacity(0.03))
                .frame(width: w, height: h)

            RoundedRectangle(cornerRadius: 12)
                .stroke(group.color.opacity(0.1), lineWidth: 1)
                .frame(width: w, height: h)

            // Circuit traces between nodes
            Canvas { context, size in
                if scaledPositions.count > 1 {
                    for i in 0..<scaledPositions.count - 1 {
                        let from = CGPoint(
                            x: scaledPositions[i].x - center.x + size.width / 2,
                            y: scaledPositions[i].y - center.y + size.height / 2
                        )
                        let to = CGPoint(
                            x: scaledPositions[i + 1].x - center.x + size.width / 2,
                            y: scaledPositions[i + 1].y - center.y + size.height / 2
                        )
                        // L-shaped circuit trace
                        var path = Path()
                        path.move(to: from)
                        let mid = CGPoint(x: to.x, y: from.y)
                        path.addLine(to: mid)
                        path.addLine(to: to)
                        context.stroke(
                            path,
                            with: .color(group.color.opacity(0.2)),
                            lineWidth: 2
                        )

                        // Node dots at corners
                        let dotSize: CGFloat = 6
                        let midRect = CGRect(x: mid.x - dotSize / 2, y: mid.y - dotSize / 2, width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: midRect), with: .color(group.color.opacity(0.4)))
                    }
                }
            }
            .frame(width: w, height: h)

            // Corner node indicators
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(group.color.opacity(0.3))
                    .frame(width: 4, height: 4)
                    .offset(
                        x: (i % 2 == 0 ? -1 : 1) * (w / 2 - 10),
                        y: (i < 2 ? -1 : 1) * (h / 2 - 10)
                    )
            }

            groupLabel(group: group, position: CGPoint(
                x: center.x,
                y: center.y - h / 2 + 15
            ))
        }
        .position(center)
        .allowsHitTesting(true)
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.3)) { editingGroupID = group.id }
        }
        .onHover { hover in hoveredGroupID = hover ? group.id : nil }
    }

    // MARK: - Group Label

    private func groupLabel(group: CanvasGroup, position: CGPoint) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(group.color)
                .frame(width: 6, height: 6)
                .shadow(color: group.color, radius: 3)

            Text(group.name)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(group.color.opacity(0.8))

            Text("·")
                .foregroundStyle(group.color.opacity(0.3))

            Text(group.style.rawValue)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(group.color.opacity(0.4))

            Text("\(group.memberPIDs.count)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(group.color.opacity(0.5))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(group.color.opacity(0.1))
                .cornerRadius(4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(group.color.opacity(0.15), lineWidth: 0.5))
        )
        .position(position)
    }

    // MARK: - Energy Connections

    private var energyConnections: some View {
        Canvas { context, _ in
            for group in groups {
                // Circuit style draws its own traces
                guard group.style != .circuit else { continue }
                let pids = Array(group.memberPIDs)
                guard pids.count > 1 else { continue }

                for i in 0..<pids.count {
                    for j in (i + 1)..<pids.count {
                        guard let from = cardPositions[pids[i]],
                              let to = cardPositions[pids[j]] else { continue }

                        let fromPt = canvasPoint(from)
                        let toPt = canvasPoint(to)

                        // Curved energy line
                        let midX = (fromPt.x + toPt.x) / 2
                        let midY = (fromPt.y + toPt.y) / 2
                        let offset = sin(energyPhase * 0.03 + Double(i + j)) * 15

                        var path = Path()
                        path.move(to: fromPt)
                        path.addQuadCurve(
                            to: toPt,
                            control: CGPoint(x: midX + CGFloat(offset), y: midY - 20 + CGFloat(offset))
                        )

                        // Draw glow layer
                        context.stroke(
                            path,
                            with: .color(group.color.opacity(0.06)),
                            lineWidth: 4
                        )
                        // Draw main line
                        context.stroke(
                            path,
                            with: .color(group.color.opacity(0.15)),
                            lineWidth: 1.5
                        )

                        // Energy particle along the path
                        let t = (sin(energyPhase * 0.04 + Double(i)) + 1) / 2
                        let px = fromPt.x + (toPt.x - fromPt.x) * t
                        let py = fromPt.y + (toPt.y - fromPt.y) * t + CGFloat(offset) * (1 - abs(2 * t - 1))
                        let particleRect = CGRect(x: px - 3, y: py - 3, width: 6, height: 6)
                        context.fill(Path(ellipseIn: particleRect), with: .color(group.color.opacity(0.6)))
                        let glowRect = CGRect(x: px - 6, y: py - 6, width: 12, height: 12)
                        context.fill(Path(ellipseIn: glowRect), with: .color(group.color.opacity(0.15)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Lasso

    private var lassoOverlay: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Instruction
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "lasso")
                        .font(.title3)
                    Text("Draw around cards to group them")
                        .font(.system(size: 13, weight: .medium))
                    Button("Cancel") {
                        withAnimation { isLassoMode = false; lassoPoints = [] }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.8))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.ultraThinMaterial))
                Spacer()
            }
            .padding(.top, 70)

            // Lasso path
            if lassoPoints.count > 1 {
                LassoShape(points: lassoPoints)
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                    .shadow(color: .cyan.opacity(0.5), radius: 4)

                LassoShape(points: lassoPoints)
                    .fill(.cyan.opacity(0.05))
            }
        }
    }

    private var lassoGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                lassoPoints.append(value.location)
            }
            .onEnded { _ in
                createGroupFromLasso()
            }
    }

    private func createGroupFromLasso() {
        guard lassoPoints.count > 3 else {
            lassoPoints = []
            return
        }

        // Find cards inside the lasso (Claude sessions + VSCode windows)
        var enclosedPIDs = monitor.sessions.filter { session in
            guard let pos = cardPositions[session.id] else { return false }
            let screenPos = canvasPoint(pos)
            return isPointInPolygon(point: screenPos, polygon: lassoPoints)
        }.map { $0.id }

        if monitor.detectVSCode {
            let vscodeIDs = monitor.vscodeWindows.filter { window in
                guard let pos = cardPositions[window.id] else { return false }
                let screenPos = canvasPoint(pos)
                return isPointInPolygon(point: screenPos, polygon: lassoPoints)
            }.map { $0.id }
            enclosedPIDs += vscodeIDs
        }

        if !enclosedPIDs.isEmpty {
            // Remove these PIDs from any existing groups
            for i in groups.indices {
                groups[i].memberPIDs.subtract(enclosedPIDs)
            }
            // Remove empty groups
            groups.removeAll { $0.memberPIDs.isEmpty }

            let newGroup = CanvasGroup.randomPreset(memberPIDs: Set(enclosedPIDs))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                groups.append(newGroup)
            }
        }

        withAnimation(.easeOut(duration: 0.2)) {
            lassoPoints = []
            isLassoMode = false
        }
    }

    // MARK: - Group Editor

    private func groupEditor(group: CanvasGroup) -> some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.3)) { editingGroupID = nil }
                }

            ScrollView {
                VStack(spacing: 16) {
                    groupEditorHeader(group: group)
                    groupEditorNameSection(group: group)
                    groupEditorColorSection(group: group)
                    groupEditorStyleSection(group: group)
                    Divider().overlay(Color.white.opacity(0.1))
                    groupEditorRulesSection(group: group)
                    Divider().overlay(Color.white.opacity(0.1))
                    groupEditorDeleteButton(group: group)
                }
                .padding(20)
            }
            .frame(width: 420)
            .frame(maxHeight: 600)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(group.color.opacity(0.2), lineWidth: 1)
                    )
            )
            .shadow(color: group.color.opacity(0.2), radius: 20)
        }
    }

    private func groupEditorHeader(group: CanvasGroup) -> some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(group.color)
            Text("Edit Group")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3)) { editingGroupID = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }

    private func groupEditorNameSection(group: CanvasGroup) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            TextField("Group name", text: $editingGroupName)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(group.color.opacity(0.2), lineWidth: 1))
                )
                .onChange(of: editingGroupName) { newName in
                    if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                        groups[idx].name = newName
                    }
                }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CanvasGroup.presetNames, id: \.self) { name in
                        Button {
                            editingGroupName = name
                        } label: {
                            Text(name)
                                .font(.system(size: 10, weight: group.name == name ? .bold : .regular))
                                .foregroundStyle(group.name == name ? group.color : .white.opacity(0.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(group.name == name ? group.color.opacity(0.15) : .white.opacity(0.05))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func groupEditorColorSection(group: CanvasGroup) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(Array(CanvasGroup.presetColors.enumerated()), id: \.offset) { _, color in
                    Button {
                        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                            withAnimation { groups[idx].color = color }
                        }
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().stroke(.white, lineWidth: group.color == color ? 2 : 0)
                            )
                            .shadow(color: color.opacity(0.5), radius: group.color == color ? 4 : 0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func groupEditorStyleSection(group: CanvasGroup) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Style")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(CanvasGroup.GroupStyle.allCases, id: \.self) { style in
                    Button {
                        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                            withAnimation { groups[idx].style = style }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: styleIcon(style))
                                .font(.system(size: 16))
                            Text(style.rawValue)
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(group.style == style ? group.color : .white.opacity(0.4))
                        .frame(width: 60, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(group.style == style ? group.color.opacity(0.12) : .white.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func groupEditorRulesSection(group: CanvasGroup) -> some View {
        VStack(spacing: 8) {
            groupEditorRulesHeader(group: group)

            if group.rules.isEmpty {
                Text("No rules. Sessions are assigned manually.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                groupEditorRulesList(group: group)

                Text("All rules must match (AND logic)")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    private func groupEditorRulesHeader(group: CanvasGroup) -> some View {
        HStack {
            Text("Rules")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            addRuleMenu(group: group)
        }
    }

    private func addRuleMenu(group: CanvasGroup) -> some View {
        Menu {
            Menu("Host App") {
                Button("VSCode") { addRule(.hostApp(.vscode), to: group) }
                Button("nvim") { addRule(.hostApp(.nvim), to: group) }
                Button("Terminal") { addRule(.hostApp(.terminal), to: group) }
            }
            Menu("Activity") {
                Button("Thinking") { addRule(.activity(.thinking), to: group) }
                Button("Running tool") { addRule(.activity(.toolRunning), to: group) }
                Button("Responding") { addRule(.activity(.responding), to: group) }
                Button("Awaiting approval") { addRule(.activity(.waitingPermission), to: group) }
                Button("Compacting") { addRule(.activity(.compacting), to: group) }
                Button("Idle") { addRule(.activity(.idle), to: group) }
            }
            Button("Path Prefix...") {
                let prefix = newRulePathPrefix.isEmpty ? "/Users" : newRulePathPrefix
                addRule(.pathPrefix(prefix), to: group)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus.circle.fill")
                Text("Add Rule")
                    .font(.system(size: 11))
            }
            .foregroundStyle(group.color)
        }
    }

    private func addRule(_ rule: GroupRule, to group: CanvasGroup) {
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            if !groups[idx].rules.contains(rule) {
                groups[idx].rules.append(rule)
                evaluateGroupRules()
            }
        }
    }

    private func groupEditorRulesList(group: CanvasGroup) -> some View {
        VStack(spacing: 6) {
            ForEach(group.rules) { rule in
                groupEditorRuleRow(group: group, rule: rule)
            }
        }
    }

    private func groupEditorRuleRow(group: CanvasGroup, rule: GroupRule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ruleIcon(rule))
                .font(.system(size: 10))
                .foregroundStyle(group.color.opacity(0.7))

            if case .pathPrefix = rule {
                TextField("Path prefix", text: Binding(
                    get: {
                        if case .pathPrefix(let p) = rule { return p }
                        return ""
                    },
                    set: { newVal in
                        if let gIdx = groups.firstIndex(where: { $0.id == group.id }),
                           let rIdx = groups[gIdx].rules.firstIndex(where: { $0.id == rule.id }) {
                            groups[gIdx].rules[rIdx] = .pathPrefix(newVal)
                            evaluateGroupRules()
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
            } else {
                Text(rule.displayLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Button {
                if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                    groups[idx].rules.removeAll { $0.id == rule.id }
                    evaluateGroupRules()
                }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.04))
        )
    }

    private func groupEditorDeleteButton(group: CanvasGroup) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                groups.removeAll { $0.id == group.id }
                editingGroupID = nil
            }
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Delete Group")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.red.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Panel

    private func detailPanel(session: ClaudeSession) -> some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                HStack {
                    ClaudeStatusView(activity: session.activity, cpuPercent: session.cpuPercent)
                        .frame(width: 50, height: 50)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.projectName).font(.headline).foregroundStyle(.white)
                        Text(session.activity.label).font(.caption).foregroundStyle(activityColor(session.activity))
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3)) { showDetail = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding()

                Divider().overlay(Color.white.opacity(0.1))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(conversationLoader.messages) { message in
                                MessageBubbleView(message: message).id(message.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: conversationLoader.messages.count) { _ in
                        if let last = conversationLoader.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.4), radius: 20, x: -5, y: 0)
            .padding(12)
        }
    }

    // MARK: - Floating Toolbar

    private var floatingToolbar: some View {
        HStack(spacing: 12) {
            Text("Claude Sessions")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("\(visibleSessions.count)/\(monitor.sessions.count) active")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }

            // Host app visibility toggle
            Button {
                withAnimation(.spring(response: 0.3)) {
                    showAllHostApps.toggle()
                    // Deselect if selected session is now hidden
                    if !showAllHostApps, let pid = selectedPID,
                       !visibleSessions.contains(where: { $0.id == pid }) {
                        selectedPID = nil
                        showDetail = false
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAllHostApps ? "eye" : "eye.slash")
                    Text(showAllHostApps ? "All" : "VSCode")
                        .font(.system(size: 11))
                }
                .foregroundStyle(showAllHostApps ? .cyan : .white.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(showAllHostApps ? .cyan.opacity(0.1) : .white.opacity(0.04))
                )
            }
            .buttonStyle(.plain)

            // VSCode detection toggle
            Button {
                withAnimation(.spring(response: 0.3)) {
                    monitor.detectVSCode.toggle()
                    if monitor.detectVSCode {
                        monitor.refresh()
                    } else {
                        // Remove VSCode window positions
                        for window in monitor.vscodeWindows {
                            cardPositions.removeValue(forKey: window.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text(monitor.detectVSCode ? "VSCode ON" : "VSCode")
                        .font(.system(size: 11))
                }
                .foregroundStyle(monitor.detectVSCode ? .blue : .white.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(monitor.detectVSCode ? .blue.opacity(0.1) : .white.opacity(0.04))
                )
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16).overlay(Color.white.opacity(0.15))

            // Grouping mode selector
            Menu {
                ForEach(GroupingMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.spring(response: 0.5)) {
                            groupingMode = mode
                            if mode != .custom {
                                applyAutoGrouping()
                            }
                        }
                    } label: {
                        Label(mode.rawValue, systemImage: mode.icon)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: groupingMode.icon)
                    Text(groupingMode.rawValue)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
            }

            // Lasso tool
            Button {
                withAnimation(.spring(response: 0.3)) {
                    isLassoMode.toggle()
                    if !isLassoMode { lassoPoints = [] }
                }
            } label: {
                Image(systemName: "lasso")
                    .foregroundStyle(isLassoMode ? .cyan : .white.opacity(0.6))
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isLassoMode ? .cyan.opacity(0.15) : .clear)
                    )
            }
            .buttonStyle(.plain)

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

            // Project launcher
            Button {
                launcher.scan(activeSessions: monitor.sessions)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showProjectList.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Launch")
                        .font(.caption)
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

    private func makeCardDragGesture(pid: Int32) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if cardDragStart[pid] == nil {
                    cardDragStart[pid] = cardPositions[pid] ?? .zero
                }
                let start = cardDragStart[pid]!
                cardPositions[pid] = CGPoint(
                    x: start.x + value.translation.width / canvasScale,
                    y: start.y + value.translation.height / canvasScale
                )
            }
            .onEnded { _ in
                // Check if card was dragged into a group
                if let pos = cardPositions[pid] {
                    snapCardToNearbyGroup(pid: pid, position: pos)
                }
                cardDragStart[pid] = nil
            }
    }

    // MARK: - Auto Grouping

    private func applyAutoGrouping() {
        groups.removeAll()

        switch groupingMode {
        case .hostApp:
            let byHost = Dictionary(grouping: monitor.sessions) { $0.hostApp }
            let colors: [HostApp: Color] = [.vscode: .blue, .nvim: .green, .terminal: .orange, .unknown: .gray]
            let styles: [HostApp: CanvasGroup.GroupStyle] = [.vscode: .circuit, .nvim: .constellation, .terminal: .nebula, .unknown: .aurora]
            for (app, sessions) in byHost {
                let group = CanvasGroup(
                    id: UUID(),
                    name: app.rawValue,
                    color: colors[app] ?? .gray,
                    memberPIDs: Set(sessions.map { $0.id }),
                    position: .zero,
                    size: .zero,
                    style: styles[app] ?? .nebula
                )
                groups.append(group)
            }

        case .activity:
            let byActivity = Dictionary(grouping: monitor.sessions) { $0.activity }
            let names: [ClaudeActivity: String] = [
                .thinking: "Thinking", .toolRunning: "Working", .responding: "Responding",
                .waitingPermission: "Awaiting", .compacting: "Compacting", .idle: "Idle"
            ]
            for (activity, sessions) in byActivity {
                let group = CanvasGroup(
                    id: UUID(),
                    name: names[activity] ?? "Unknown",
                    color: activity.color,
                    memberPIDs: Set(sessions.map { $0.id }),
                    position: .zero,
                    size: .zero,
                    style: .nebula
                )
                groups.append(group)
            }

        case .vscode:
            // Group 1: VSCode + Claude
            let vscodeClaude = monitor.sessions.filter { $0.hostApp == .vscode }
            if !vscodeClaude.isEmpty {
                let group = CanvasGroup(
                    id: UUID(),
                    name: "VSCode + Claude",
                    color: .blue,
                    memberPIDs: Set(vscodeClaude.map { $0.id }),
                    position: .zero,
                    size: .zero,
                    style: .circuit
                )
                groups.append(group)
            }

            // Group 2: VSCode Only (no Claude)
            if !monitor.vscodeWindows.isEmpty {
                let group = CanvasGroup(
                    id: UUID(),
                    name: "VSCode Only",
                    color: .gray,
                    memberPIDs: Set(monitor.vscodeWindows.map { $0.id }),
                    position: .zero,
                    size: .zero,
                    style: .constellation
                )
                groups.append(group)
            }

        case .custom:
            break
        }

        autoLayoutAllCards()
    }

    // MARK: - Layout

    private func autoLayoutNewCards() {
        let totalCount = monitor.sessions.count + (monitor.detectVSCode ? monitor.vscodeWindows.count : 0)
        for (index, session) in monitor.sessions.enumerated() {
            if cardPositions[session.id] == nil {
                let angle = Double(index) * (2 * .pi / max(Double(totalCount), 1))
                let radius: CGFloat = 200
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    cardPositions[session.id] = CGPoint(
                        x: 400 + radius * CGFloat(cos(angle)),
                        y: 300 + radius * CGFloat(sin(angle))
                    )
                }
            }
        }
        if monitor.detectVSCode {
            for (index, window) in monitor.vscodeWindows.enumerated() {
                if cardPositions[window.id] == nil {
                    let angle = Double(monitor.sessions.count + index) * (2 * .pi / max(Double(totalCount), 1))
                    let radius: CGFloat = 200
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                        cardPositions[window.id] = CGPoint(
                            x: 400 + radius * CGFloat(cos(angle)),
                            y: 300 + radius * CGFloat(sin(angle))
                        )
                    }
                }
            }
        }
    }

    private var allCardIDs: [Int32] {
        var ids = monitor.sessions.map { $0.id }
        if monitor.detectVSCode {
            ids += monitor.vscodeWindows.map { $0.id }
        }
        return ids
    }

    private func autoLayoutAllCards() {
        let allIDs = allCardIDs
        if groups.isEmpty {
            // No groups: circular layout
            for (i, id) in allIDs.enumerated() {
                let angle = Double(i) * (2 * .pi / max(Double(allIDs.count), 1)) - .pi / 2
                let radius: CGFloat = allIDs.count == 1 ? 0 : CGFloat(80 + allIDs.count * 40)
                cardPositions[id] = CGPoint(
                    x: 400 + radius * CGFloat(cos(angle)),
                    y: 300 + radius * CGFloat(sin(angle))
                )
            }
        } else {
            // Layout by groups in clusters
            var groupIndex = 0
            let ungroupedIDs = Set(allIDs).subtracting(groups.flatMap { $0.memberPIDs })

            for group in groups {
                let pids = Array(group.memberPIDs)
                let groupCenterX: CGFloat = 350 + CGFloat(groupIndex) * 400
                let groupCenterY: CGFloat = 300

                for (i, pid) in pids.enumerated() {
                    let angle = Double(i) * (2 * .pi / max(Double(pids.count), 1)) - .pi / 2
                    let radius: CGFloat = pids.count == 1 ? 0 : CGFloat(60 + pids.count * 30)
                    cardPositions[pid] = CGPoint(
                        x: groupCenterX + radius * CGFloat(cos(angle)),
                        y: groupCenterY + radius * CGFloat(sin(angle))
                    )
                }
                groupIndex += 1
            }

            // Ungrouped cards
            let ungrouped = Array(ungroupedIDs)
            if !ungrouped.isEmpty {
                let startX: CGFloat = 350 + CGFloat(groupIndex) * 400
                for (i, pid) in ungrouped.enumerated() {
                    let angle = Double(i) * (2 * .pi / max(Double(ungrouped.count), 1)) - .pi / 2
                    let radius: CGFloat = ungrouped.count == 1 ? 0 : 80
                    cardPositions[pid] = CGPoint(
                        x: startX + radius * CGFloat(cos(angle)),
                        y: 300 + radius * CGFloat(sin(angle))
                    )
                }
            }
        }
    }

    // MARK: - Snap to Group

    private func snapCardToNearbyGroup(pid: Int32, position: CGPoint) {
        guard groupingMode == .custom else { return }

        for i in groups.indices {
            let memberPositions = groups[i].memberPIDs.compactMap { cardPositions[$0] }
            guard !memberPositions.isEmpty else { continue }

            let bounds = groupBounds(positions: memberPositions, padding: 120)
            if position.x >= bounds.center.x - bounds.size.width / 2 &&
               position.x <= bounds.center.x + bounds.size.width / 2 &&
               position.y >= bounds.center.y - bounds.size.height / 2 &&
               position.y <= bounds.center.y + bounds.size.height / 2 {
                // Remove from other groups
                for j in groups.indices where j != i {
                    groups[j].memberPIDs.remove(pid)
                }
                withAnimation(.spring(response: 0.3)) {
                    groups[i].memberPIDs.insert(pid)
                }
                // Clean up empty groups
                groups.removeAll { $0.memberPIDs.isEmpty }
                return
            }
        }
    }

    // MARK: - Group Rule Evaluation

    private func evaluateGroupRules() {
        for i in groups.indices {
            guard !groups[i].rules.isEmpty else { continue }
            let matchingSessions = monitor.sessions.filter { session in
                groups[i].rules.allSatisfy { $0.matches(session) }
            }
            for session in matchingSessions {
                groups[i].memberPIDs.insert(session.id)
            }
        }
    }

    private func ruleIcon(_ rule: GroupRule) -> String {
        switch rule {
        case .hostApp: return "desktopcomputer"
        case .activity: return "bolt.circle"
        case .pathPrefix: return "folder"
        }
    }

    // MARK: - Helpers

    private func canvasPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: p.x * canvasScale + canvasOffset.width,
            y: p.y * canvasScale + canvasOffset.height
        )
    }

    private func groupBounds(positions: [CGPoint], padding: CGFloat) -> (center: CGPoint, size: CGSize) {
        let minX = positions.map(\.x).min()! - padding
        let maxX = positions.map(\.x).max()! + padding
        let minY = positions.map(\.y).min()! - padding
        let maxY = positions.map(\.y).max()! + padding
        return (
            center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
            size: CGSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func activityColor(_ activity: ClaudeActivity) -> Color {
        activity.color
    }

    private func styleIcon(_ style: CanvasGroup.GroupStyle) -> String {
        switch style {
        case .nebula: return "cloud"
        case .constellation: return "star"
        case .aurora: return "wind"
        case .circuit: return "cpu"
        }
    }

    private func isPointInPolygon(point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y) &&
               point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private func startEnergyAnimation() {
        energyTimer?.invalidate()
        energyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            energyPhase += 1
        }
    }
}

// MARK: - Custom Shapes

struct WaveShape: Shape {
    var phase: Double
    var amplitude: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: midY))

        for x in stride(from: rect.minX, through: rect.maxX, by: 2) {
            let relX = (x - rect.minX) / rect.width
            let y = midY + CGFloat(sin(relX * .pi * 4 + phase) * amplitude)
            path.addLine(to: CGPoint(x: x, y: y))
        }

        return path
    }
}

struct LassoShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

