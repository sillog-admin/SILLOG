import Foundation

extension ConversationMessage {
    /// The text followed by its sources, numbered as the [n] marks in the answer.
    public var markdown: String {
        guard !sources.isEmpty else { return text }
        let list = sources.enumerated().map { index, source in
            "\(index + 1). \(source.title)" + (source.location.isEmpty ? "" : " — \(source.location)")
        }
        return text + "\n\n**\(tr("출처"))**\n\n" + list.joined(separator: "\n")
    }

    /// Args: title is the conversation title, messages the conversation in order.
    /// Returns: the conversation as Markdown, each turn with its sources. Answers still running are left out.
    /// Raises: none.
    public static func markdown(title: String, messages: [ConversationMessage]) -> String {
        let turns = messages.filter { $0.status != "running" }.map { message -> String in
            "## \(message.role == "user" ? tr("질문") : tr("답변"))\n\n\(message.markdown)"
        }
        return (["# \(title)"] + turns).joined(separator: "\n\n") + "\n"
    }
}
