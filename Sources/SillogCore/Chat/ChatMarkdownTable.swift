import Foundation

/// 채팅 본문에서 표로만 구성된 Markdown 블록을 해석한다.
public enum ChatMarkdownTable {
    /// Args: text is one Markdown block between blank lines.
    /// Returns: rows including the header, or nil when it is not a table. Body rows are padded or cut to the header width as in GFM, so a row still streaming in keeps the table.
    /// Raises: none.
    public static func rows(in text: String) -> [[String]]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return nil }
        let header = cells(in: lines[0])
        let separator = cells(in: lines[1])
        guard header.count >= 2, separator.count == header.count,
              separator.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        let body = lines.dropFirst(2).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(cells)
            .map { Array(($0 + Array(repeating: "", count: header.count)).prefix(header.count)) }
        return [header] + body
    }

    /// Args: line은 표의 한 행이다.
    /// Returns: 양끝 파이프를 제외하고 분리한 셀 목록.
    /// Raises: 없음.
    private static func cells(in line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
