import Foundation

final class SessionResolver {
    private let claudeProjectsDir: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeProjectsDir = "\(home)/.claude/projects"
    }

    /// cwd (e.g. /Users/foo/my-workspace/news) → 最新の .jsonl ファイルパス
    func resolveJSONLPath(cwd: String) -> String? {
        // Claude Code replaces "/", ".", and "_" with "-"
        let projectDirName = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let projectDir = "\(claudeProjectsDir)/\(projectDirName)"

        // Find the most recently modified .jsonl file
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectDir) else { return nil }

        do {
            let files = try fm.contentsOfDirectory(atPath: projectDir)
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }

            var latestFile: String?
            var latestDate: Date = .distantPast

            for file in jsonlFiles {
                let fullPath = "\(projectDir)/\(file)"
                let attrs = try fm.attributesOfItem(atPath: fullPath)
                if let modDate = attrs[.modificationDate] as? Date, modDate > latestDate {
                    latestDate = modDate
                    latestFile = fullPath
                }
            }

            return latestFile
        } catch {
            return nil
        }
    }
}
