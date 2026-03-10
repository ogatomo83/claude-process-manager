import Foundation

enum MessageRole: String {
    case user
    case assistant
    case system
    case tool
}

struct ConversationMessage: Identifiable {
    let id: String // uuid
    let role: MessageRole
    let content: String
    let toolName: String?
    let timestamp: Date?

    var displayContent: String {
        if let toolName = toolName {
            return "[\(toolName)] \(content)"
        }
        return content
    }
}
