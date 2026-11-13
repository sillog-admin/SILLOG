import Foundation

extension ConversationMessage {
    /// The text followed by its sources, each with the ID the answer cites.
    public var markdown: String {
        guard !sources.isEmpty else { return text }
        let list = sources.map { source in
            "- [\(source.id)] \(ChatRunner.displayTitle(source.title))" + (source.location.isEmpty ? "" : " — \(source.location)")
        }
        return text + "\n\n**\(tr("출처"))**\n\n" + list.joined(separator: "\n")
    }

    /// Args: markdown is a message's text.
    /// Returns: the text without Markdown markers, lines joined by spaces, for a short preview.
    /// Raises: none.
    public static func plainText(_ markdown: String) -> String {
        var text = markdown
        for (pattern, template) in [
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(?m)^[ \t]*```[\w+-]*"#, ""),
            (#"(?m)^[ \t]*(#{1,6}|>|[-*+]|\d+[.)])[ \t]+"#, ""),
            (#"\*\*|__|~~|`+"#, ""),
        ] { text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
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
