import SwiftUI
import AppKit

struct CommandPaletteView: View {
    @ObservedObject var launcher: ProjectLauncher
    @Binding var isVisible: Bool

    @State private var inputText: String = ""
    @State private var selectedIndex: Int = 0
    @State private var keyMonitor: Any? = nil
    @FocusState private var isInputFocused: Bool

    // MARK: - Command Parsing

    private enum ParsedCommand {
        case empty                          // nothing typed yet
        case openAll                        // "open" with no query
        case openQuery(String)              // "open <query>"
        case unknown(String)                // unrecognized command
    }

    private var parsed: ParsedCommand {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }

        if trimmed.lowercased() == "open" {
            return .openAll
        }
        if trimmed.lowercased().hasPrefix("open ") {
            let query = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return query.isEmpty ? .openAll : .openQuery(query)
        }
        // Partial match for "open" (e.g. "op", "ope")
        if "open".hasPrefix(trimmed.lowercased()) {
            return .empty
        }
        return .unknown(trimmed)
    }

    private var filteredProjects: [ProjectEntry] {
        switch parsed {
        case .openAll:
            return launcher.projects
        case .openQuery(let query):
            return launcher.projects.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
        default:
            return []
        }
    }

    private var showSuggestions: Bool {
        switch parsed {
        case .openAll, .openQuery: return true
        default: return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Input row
            HStack(spacing: 0) {
                Text("/")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.leading, 14)

                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.white)
                    .focused($isInputFocused)
                    .padding(.vertical, 12)
                    .padding(.trailing, 14)
            }

            // Suggestions / status
            switch parsed {
            case .empty:
                commandHint("open", description: "Open project in VSCode + Claude")

            case .unknown(let cmd):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text("Unknown command: \(cmd)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            case .openAll, .openQuery:
                if filteredProjects.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.3))
                        Text("No matching projects")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                } else {
                    Divider().overlay(Color.white.opacity(0.1))
                    suggestionList
                }
            }
        }
        .frame(width: 500)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.1, green: 0.1, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
        .onAppear {
            inputText = ""
            selectedIndex = 0
            isInputFocused = true
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: inputText) { _, _ in
            selectedIndex = 0
        }
    }

    // MARK: - Subviews

    private func commandHint(_ command: String, description: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.cyan)
            Text(description)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredProjects.enumerated()), id: \.element.id) { index, project in
                        suggestionRow(project: project, index: index)
                            .id(project.id)
                    }
                }
            }
            .frame(maxHeight: 300)
            .onChange(of: selectedIndex) { _, newIndex in
                let projects = filteredProjects
                if newIndex >= 0, newIndex < projects.count {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(projects[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func suggestionRow(project: ProjectEntry, index: Int) -> some View {
        let isSelected = index == selectedIndex

        return HStack(spacing: 8) {
            Text(isSelected ? "▸" : " ")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 14)

            Text(project.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text("~/\(project.parentDir)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)

            Spacer()

            if project.hasClaudeSession {
                Circle().fill(.green).frame(width: 6, height: 6)
            } else if project.isVSCodeOpen {
                Circle().fill(.blue).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? Color.cyan.opacity(0.1) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            launchAndHide(project: project)
        }
    }

    // MARK: - Actions

    private func launchAndHide(project: ProjectEntry) {
        launcher.launch(project: project)
        isVisible = false
        GlobalHotkeyService.shared.toggleWindow()
    }

    private func tabComplete() {
        let projects = filteredProjects
        guard let first = projects.first else { return }
        inputText = "open \(first.name)"
    }

    // MARK: - Keyboard Monitor

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let hasControl = event.modifierFlags.contains(.control)

            // Escape: close palette
            if keyCode == 53 {
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.3)) { isVisible = false }
                }
                return nil
            }

            // Tab: autocomplete
            if keyCode == 48 {
                DispatchQueue.main.async { tabComplete() }
                return nil
            }

            // Enter: launch selected
            if keyCode == 36 {
                DispatchQueue.main.async {
                    let projects = filteredProjects
                    if selectedIndex >= 0, selectedIndex < projects.count {
                        launchAndHide(project: projects[selectedIndex])
                    }
                }
                return nil
            }

            // Ctrl+N: move down
            if hasControl && keyCode == 45 {
                DispatchQueue.main.async {
                    let projects = filteredProjects
                    if selectedIndex < projects.count - 1 {
                        selectedIndex += 1
                    }
                }
                return nil
            }

            // Ctrl+P: move up
            if hasControl && keyCode == 35 {
                DispatchQueue.main.async {
                    if selectedIndex > 0 {
                        selectedIndex -= 1
                    }
                }
                return nil
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
