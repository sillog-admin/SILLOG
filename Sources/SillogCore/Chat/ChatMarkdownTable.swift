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

    /// Fits columns to the available width like an HTML auto table: full widths when they fit, otherwise each column keeps its floor and the rest is shared in proportion to how much it wants.
    /// Args: ideal is each column's one-line width, minimum the floor for a wrapped column, available the width to fill.
    /// Returns: column widths. Their sum exceeds available only when the floors alone do not fit.
    /// Raises: none.
    public static func columnWidths(ideal: [Double], minimum: Double, available: Double) -> [Double] {
        guard ideal.reduce(0, +) > available else { return ideal }
        let floors = ideal.map { min($0, minimum) }
        let spare = available - floors.reduce(0, +)
        guard spare > 0 else { return floors }
        let wanted = zip(ideal, floors).map { $0 - $1 }
        let total = wanted.reduce(0, +)
        return zip(floors, wanted).map { $0 + $1 / total * spare }
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
