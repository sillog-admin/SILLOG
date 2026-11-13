import Foundation

/// One tool a conversation used, for the chat header's activity panel.
public struct ChatToolUse: Equatable, Identifiable, Sendable {
    /// The stored Korean step title; show it with ChatRunner.displayTitle.
    public var title: String
    public var count: Int
    public var lastMessageID: String
    public var id: String { title }
}

extension ConversationMessage {
    /// Args: messages is the conversation in order.
    /// Returns: each tool its answers called, most used first, with the latest answer that called it. A helper's tools count under the tool's own name.
    /// Raises: none.
    public static func toolUses(in messages: [ConversationMessage]) -> [ChatToolUse] {
        var uses: [ChatToolUse] = []
        for message in messages {
            for step in message.trace ?? message.steps.map({ ChatStep(title: $0, status: .done) }) where step.kind != .reasoning {
                let title = step.title.components(separatedBy: " · ").last ?? step.title
                // "<helper> 시작/완료" mark a delegated task's span, not a tool call.
                if title.isEmpty || title.hasSuffix(" 시작") || title.hasSuffix(" 완료") { continue }
                if let index = uses.firstIndex(where: { $0.title == title }) {
                    uses[index].count += 1; uses[index].lastMessageID = message.id
                } else {
                    uses.append(ChatToolUse(title: title, count: 1, lastMessageID: message.id))
                }
            }
        }
        return uses.enumerated().sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }.map(\.element)
    }
}
