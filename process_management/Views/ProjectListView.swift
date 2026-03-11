import SwiftUI

struct ProjectListView: View {
    @ObservedObject var launcher: ProjectLauncher
    @Binding var isVisible: Bool
    @State private var searchText: String = ""
    @State private var hoveredProject: String? = nil

    private var filteredProjects: [ProjectEntry] {
        if searchText.isEmpty {
            return launcher.projects
        }
        return launcher.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedProjects: [(parent: String, projects: [ProjectEntry])] {
        let dict = Dictionary(grouping: filteredProjects) { $0.parentDir }
        return dict.sorted { $0.key < $1.key }.map { (parent: $0.key, projects: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.grid.badge.plus")
                    .foregroundStyle(.cyan)
                Text("Projects")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) { isVisible = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding()

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search projects...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
            }
            .padding(8)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider().overlay(Color.white.opacity(0.1))

            // Project list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groupedProjects, id: \.parent) { group in
                        Section {
                            ForEach(group.projects) { project in
                                projectRow(project)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                Text("~/\(group.parent)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text("\(group.projects.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 320, height: 500)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
    }

    private func projectRow(_ project: ProjectEntry) -> some View {
        HStack(spacing: 10) {
            // Status indicators
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(statusColor(project).opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: statusIcon(project))
                    .font(.system(size: 14))
                    .foregroundStyle(statusColor(project))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if project.hasClaudeSession {
                        HStack(spacing: 3) {
                            Circle().fill(.green).frame(width: 4, height: 4)
                            Text("Claude active")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                        }
                    }
                    if project.isVSCodeOpen {
                        HStack(spacing: 3) {
                            Circle().fill(.blue).frame(width: 4, height: 4)
                            Text("VSCode open")
                                .font(.system(size: 9))
                                .foregroundStyle(.blue)
                        }
                    }
                    if !project.hasClaudeSession && !project.isVSCodeOpen {
                        Text("Not running")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }

            Spacer()

            // Launch button
            if !project.hasClaudeSession {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan.opacity(hoveredProject == project.id ? 1 : 0.5))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hoveredProject == project.id ? Color.white.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered in
            hoveredProject = isHovered ? project.id : nil
        }
        .onTapGesture(count: 2) {
            launcher.launch(project: project)
            withAnimation(.spring(response: 0.3)) { isVisible = false }
        }
    }

    private func statusColor(_ project: ProjectEntry) -> Color {
        if project.hasClaudeSession { return .green }
        if project.isVSCodeOpen { return .blue }
        return .white.opacity(0.3)
    }

    private func statusIcon(_ project: ProjectEntry) -> String {
        if project.hasClaudeSession { return "sparkle" }
        if project.isVSCodeOpen { return "chevron.left.forwardslash.chevron.right" }
        return "folder"
    }
}
