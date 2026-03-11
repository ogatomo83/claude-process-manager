import Foundation

struct VSCodeWindow: Identifiable, Equatable {
    let id: Int32           // negative Int32 (from title hash)
    let windowTitle: String // e.g. "project_name — Visual Studio Code"
    let projectName: String // parsed from title

    init(windowTitle: String) {
        self.windowTitle = windowTitle
        // Extract project name: "project — Visual Studio Code" → "project"
        let parts = windowTitle.components(separatedBy: " — ")
        self.projectName = parts.first?.trimmingCharacters(in: .whitespaces) ?? windowTitle
        // Use negative hash to avoid collision with positive PIDs
        let hash = abs(windowTitle.hashValue) % Int(Int32.max)
        self.id = -Int32(max(hash, 1))
    }
}
