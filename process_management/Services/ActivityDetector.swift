import Foundation

/// Shared logic for detecting `ClaudeActivity` from a JSONL session file tail.
///
/// Used by:
/// - `ProcessMonitor` — polls every 3s across all sessions (64KB tail, logging on)
/// - `ConversationLoader` — one-shot on initial load (8KB tail, logging off)
///
/// `detectActivityFromLine` in `ConversationLoader` is a separate single-line
/// streaming parser and is intentionally not consolidated here.
enum ActivityDetector {
    /// Read the tail of a JSONL session file and determine the current activity.
    /// - Parameters:
    ///   - jsonlPath: Absolute path to the `.jsonl` file, or `nil` → returns `.idle`.
    ///   - chunkSize: Number of bytes to read from the end of the file.
    ///   - enableLogging: If `true`, writes decision events to `ActivityLogger.logPoll`.
    static func detect(
        jsonlPath: String?,
        chunkSize: UInt64 = 65536,
        enableLogging: Bool = false
    ) -> ClaudeActivity {
        guard let path = jsonlPath,
              let fh = FileHandle(forReadingAtPath: path) else { return .idle }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else { return .idle }

        let modDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date.distantPast
        let secondsSinceModified = Date().timeIntervalSince(modDate)
        let isStaleForIdle = secondsSinceModified > 10

        let readChunk = min(fileSize, chunkSize)
        fh.seek(toFileOffset: fileSize - readChunk)
        let data = fh.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else { return .idle }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let project = (path as NSString).lastPathComponent.prefix(8)

        func log(_ event: String, _ result: ClaudeActivity) {
            guard enableLogging else { return }
            ActivityLogger.shared.logPoll(
                pid: 0,
                project: String(project),
                event: event,
                result: result
            )
        }

        // stale 判定: ファイルが一定時間更新されていない場合の扱い
        // - assistant(text) + stale → idle (ターン完了、turn_duration なし)
        // - user(text) + stale → thinking (API 応答待ち、時間がかかることがある)
        // - progress/tool_use + stale → waitingPermission (ユーザー承認待ち)
        // - assistant(thinking) + stale → thinking (思考に時間がかかる)
        var sawTurnDuration = false

        for line in lines.reversed() {
            let s = String(line)

            guard let jsonData = s.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            switch type {
            case "file-history-snapshot":
                continue

            case "progress":
                // progress がある = ツールは承認済み・実行中
                // サブエージェント等は progress が断続的 (10-15秒間隔) なので stale でも toolRunning
                log("progress", .toolRunning)
                return .toolRunning

            case "system":
                let subtype = json["subtype"] as? String ?? ""
                if subtype == "turn_duration" {
                    sawTurnDuration = true
                    continue
                }
                if subtype == "compact_boundary" {
                    let r: ClaudeActivity = secondsSinceModified > 30 ? .idle : .compacting
                    log("compact_boundary(\(Int(secondsSinceModified))s)", r)
                    return r
                }
                continue

            case "user":
                if let message = json["message"] as? [String: Any],
                   let contentArray = message["content"] as? [[String: Any]] {
                    let isToolResult = contentArray.contains { ($0["type"] as? String) == "tool_result" }
                    if isToolResult {
                        // tool_result = ツール実行済み → Claude が次のレスポンスを考え始める
                        // API 呼び出しに 10 秒以上かかることがあるので stale でも thinking
                        let r: ClaudeActivity = sawTurnDuration ? .idle : .thinking
                        log("user(tool_result) sawTD=\(sawTurnDuration)", r)
                        return r
                    }
                }
                // user(text) + stale → まだ thinking (API は 10 秒以上かかることがある)
                let r: ClaudeActivity = sawTurnDuration ? .idle : .thinking
                log("user(text) sawTD=\(sawTurnDuration)", r)
                return r

            case "assistant":
                guard let msg = json["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else {
                    let r: ClaudeActivity = (sawTurnDuration || isStaleForIdle) ? .idle : .responding
                    log("assistant(no-content) sawTD=\(sawTurnDuration) stale=\(isStaleForIdle)", r)
                    return r
                }
                let blockTypes = blocks.compactMap { $0["type"] as? String }
                let blockDesc = blockTypes.joined(separator: ",")

                // thinking only → thinking (stale でも thinking 維持)
                if blockTypes.contains("thinking") && !blockTypes.contains("text") && !blockTypes.contains("tool_use") {
                    let r: ClaudeActivity = sawTurnDuration ? .idle : .thinking
                    log("assistant(\(blockDesc)) sawTD=\(sawTurnDuration)", r)
                    return r
                }
                // tool_use → waitingPermission (承認待ち)
                // tool_result が後にあるケースは user(tool_result) で先に thinking を返すため到達しない
                if blockTypes.contains("tool_use") {
                    if sawTurnDuration {
                        log("assistant(tool_use) sawTD=true", .idle)
                        return .idle
                    }
                    let toolName = blocks.first(where: { $0["type"] as? String == "tool_use" })?["name"] as? String ?? "?"
                    log("assistant(tool_use:\(toolName))", .waitingPermission)
                    return .waitingPermission
                }
                // assistant(text) + stale → idle (ターン完了、turn_duration なし)
                let r: ClaudeActivity = (sawTurnDuration || isStaleForIdle) ? .idle : .responding
                log("assistant(\(blockDesc)) sawTD=\(sawTurnDuration) stale=\(isStaleForIdle)", r)
                return r

            default:
                continue
            }
        }
        return .idle
    }
}
