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

    /// Args: markdown is a message's text, separator what joins its non-empty lines.
    /// Returns: the text without Markdown markers, lines joined by spaces unless told otherwise, for a short preview.
    /// Raises: none.
    public static func plainText(_ markdown: String, separator: String = " ") -> String {
        var text = markdown
        for (pattern, template) in [
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(?m)^[ \t]*```[\w+-]*"#, ""),
            (#"(?m)^[ \t]*(#{1,6}|>|[-*+]|\d+[.)])[ \t]+"#, ""),
            (#"\*\*|__|~~|`+"#, ""),
        ] { text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: separator)
    }

    /// The answer as plain text to read aloud: citations, code blocks, table bars and Markdown markers dropped, one line per paragraph or item.
    public var speechText: String {
        var text = sources.reduce(self.text) { $0.replacingOccurrences(of: "[\($1.id)]", with: "") }
        for (pattern, template) in [
            (#"(?ms)^[ \t]*```.*?^[ \t]*```[ \t]*$"#, ""),
            (#"(?m)^[ \t|:-]+$"#, ""),
            (#"\|"#, " "),
        ] { text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        return Self.plainText(text, separator: "\n")
    }

    /// Args: messages is a conversation in order, calendar the one that tells days apart.
    /// Returns: ids of the messages sent an hour or more after the previous one ended, or on a later day; each gets a time divider above it.
    /// Raises: none.
    public static func timeDividerIDs(in messages: [ConversationMessage], calendar: Calendar = .current) -> Set<String> {
        Set(zip(messages, messages.dropFirst()).compactMap { previous, message in
            let last = previous.completedAt ?? previous.createdAt
            let sameDay = calendar.isDate(Date(timeIntervalSince1970: last), inSameDayAs: Date(timeIntervalSince1970: message.createdAt))
            return message.role == "user" && (message.createdAt - last >= 3600 || !sameDay) ? message.id : nil
        })
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
