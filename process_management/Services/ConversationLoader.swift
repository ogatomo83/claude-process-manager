import Foundation
import Combine

final class ConversationLoader: ObservableObject {
    @Published var messages: [ConversationMessage] = []
    @Published var activity: ClaudeActivity = .idle

    private var dispatchSource: DispatchSourceFileSystemObject?
    private var monitorFileHandle: FileHandle?
    private var currentPath: String?
    private var lastReadOffset: UInt64 = 0

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func load(jsonlPath: String) {
        stop()
        currentPath = jsonlPath
        lastReadOffset = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let parsed = self.loadTail(path: jsonlPath, maxMessages: 50)

            let detectedActivity = self.detectActivity(path: jsonlPath)

            DispatchQueue.main.async {
                self.messages = parsed
                self.activity = detectedActivity
            }

            self.startWatching(path: jsonlPath)
        }
    }

    func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
        monitorFileHandle?.closeFile()
        monitorFileHandle = nil
        currentPath = nil
    }

    // MARK: - Initial Load (tail read)

    /// Read only the tail of the file to find the last N displayable messages
    private func loadTail(path: String, maxMessages: Int) -> [ConversationMessage] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else { return [] }

        // Read the last chunk (128KB should be enough for ~50 messages)
        let chunkSize: UInt64 = min(fileSize, 128 * 1024)
        let readOffset = fileSize - chunkSize
        fh.seek(toFileOffset: readOffset)
        let tailData = fh.readDataToEndOfFile()
        lastReadOffset = fileSize

        guard let content = String(data: tailData, encoding: .utf8) else { return [] }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var parsed: [ConversationMessage] = []

        // Parse from the end, stop when we have enough
        for line in lines.reversed() {
            let lineStr = String(line)
            // Quick pre-filter: skip lines that can't be user/assistant messages
            guard lineStr.contains("\"user\"") || lineStr.contains("\"assistant\"") else { continue }

            if let msg = parseLine(lineStr) {
                parsed.append(msg)
                if parsed.count >= maxMessages { break }
            }
        }

        return parsed.reversed()
    }

    // MARK: - File Watching

    private func startWatching(path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        monitorFileHandle = fh

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fh.fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.readNewContent()
        }

        source.setCancelHandler {
            fh.closeFile()
        }

        dispatchSource = source
        source.resume()
    }

    private func readNewContent() {
        guard let path = currentPath,
              let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > lastReadOffset else { return }

        fh.seek(toFileOffset: lastReadOffset)
        let newData = fh.readDataToEndOfFile()
        lastReadOffset = fileSize

        guard let content = String(data: newData, encoding: .utf8) else { return }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var newMessages: [ConversationMessage] = []
        var latestActivity: ClaudeActivity?

        for line in lines {
            let lineStr = String(line)

            // Detect activity from all lines (including progress)
            latestActivity = detectActivityFromLine(lineStr) ?? latestActivity

            guard lineStr.contains("\"user\"") || lineStr.contains("\"assistant\"") else { continue }
            if let msg = parseLine(lineStr) {
                newMessages.append(msg)
            }
        }

        DispatchQueue.main.async {
            if !newMessages.isEmpty {
                self.messages.append(contentsOf: newMessages)
            }
            if let activity = latestActivity {
                self.activity = activity
            }
        }
    }

    // MARK: - Parsing

    private func parseLine(_ line: String) -> ConversationMessage? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = json["type"] as? String ?? ""
        guard type == "user" || type == "assistant" else { return nil }

        guard let message = json["message"] as? [String: Any] else { return nil }

        let uuid = json["uuid"] as? String ?? UUID().uuidString

        var timestamp: Date?
        if let ts = json["timestamp"] as? String {
            timestamp = Self.timestampFormatter.date(from: ts)
        }

        switch type {
        case "user":
            let content = extractTextContent(from: message)
            guard !content.isEmpty else { return nil }
            return ConversationMessage(
                id: uuid, role: .user, content: content,
                toolName: nil, timestamp: timestamp
            )

        case "assistant":
            guard let contentArray = message["content"] as? [[String: Any]] else { return nil }
            for block in contentArray {
                let blockType = block["type"] as? String ?? ""

                if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                    return ConversationMessage(
                        id: uuid, role: .assistant, content: text,
                        toolName: nil, timestamp: timestamp
                    )
                }

                if blockType == "tool_use" {
                    let toolName = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let summary = toolInputSummary(toolName: toolName, input: input)
                    return ConversationMessage(
                        id: uuid, role: .tool, content: summary,
                        toolName: toolName, timestamp: timestamp
                    )
                }
            }
            return nil

        default:
            return nil
        }
    }

    private func extractTextContent(from message: [String: Any]) -> String {
        if let content = message["content"] as? String {
            return content
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            for block in contentArray {
                if block["type"] as? String == "text", let text = block["text"] as? String {
                    return text
                }
            }
        }
        return ""
    }

    private func toolInputSummary(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            return String(cmd.prefix(120))
        case "Read", "Write", "Edit":
            let path = input["file_path"] as? String ?? ""
            return (path as NSString).lastPathComponent
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "Grep":
            return input["pattern"] as? String ?? ""
        case "Task":
            return input["description"] as? String ?? ""
        default:
            return toolName
        }
    }

    // MARK: - Activity Detection

    /// Read the last few lines of the JSONL to determine current activity
    private func detectActivity(path: String) -> ClaudeActivity {
        guard let fh = FileHandle(forReadingAtPath: path) else { return .idle }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        let chunkSize: UInt64 = min(fileSize, 4096)
        fh.seek(toFileOffset: fileSize - chunkSize)
        let data = fh.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else { return .idle }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        // Check from the last line backwards
        for line in lines.reversed() {
            if let activity = detectActivityFromLine(String(line)) {
                return activity
            }
        }
        return .idle
    }

    /// Determine activity from a single JSONL line
    private func detectActivityFromLine(_ line: String) -> ClaudeActivity? {
        // Quick string checks before JSON parsing
        if line.contains("\"progress\"") {
            return .toolRunning
        }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = json["type"] as? String ?? ""

        switch type {
        case "user":
            return .thinking

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let contentArray = message["content"] as? [[String: Any]] else { return nil }
            for block in contentArray {
                let blockType = block["type"] as? String ?? ""
                if blockType == "tool_use" { return .toolRunning }
                if blockType == "text" { return .responding }
            }
            return .responding

        case "progress":
            return .toolRunning

        default:
            return nil
        }
    }
}
