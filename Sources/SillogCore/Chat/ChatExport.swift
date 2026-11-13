import Foundation

extension ConversationMessage {
    /// The sources the text cites as [id], and the other items its tools looked up, each in stored order.
    public var splitSources: (cited: [ChatSource], other: [ChatSource]) {
        let cites = { (source: ChatSource) in text.contains("[\(source.id)]") }
        return (sources.filter(cites), sources.filter { !cites($0) })
    }

    /// The text followed by the sources it cites, each with the ID the answer uses.
    public var markdown: String {
        let cited = splitSources.cited
        guard !cited.isEmpty else { return text }
        let list = cited.map { source in
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
