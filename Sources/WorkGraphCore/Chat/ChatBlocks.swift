import Foundation

/// 채팅 본문 한 덩어리(빈 줄 사이)를 줄 단위 블록으로 나눈다: 제목(그 줄만), 문단, 목록, 인용, 구분선.
/// 표·코드 블록은 이 앞에서 따로 처리한다.
public enum ChatBlocks {
    public struct Item: Equatable, Sendable {
        /// 들여쓰기 단계 (공백 2칸 = 1단계, 최대 3)
        public var level: Int
        /// 글머리는 "•", 번호 목록은 쓴 그대로 ("1.", "2)")
        public var marker: String
        public var text: String
        public init(level: Int, marker: String, text: String) { self.level = level; self.marker = marker; self.text = text }
    }

    public enum Block: Equatable, Sendable {
        case heading(Int, String)
        case paragraph(String)
        case list([Item])
        case quote(String)
        case divider
    }

    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$"#)
    private static let dividerPattern = try! NSRegularExpression(pattern: #"^[ ]{0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^[ ]{0,3}>[ ]?(.*)$"#)
    private static let itemPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+•]|\d{1,3}[.)])[ \t]+(.*)$"#)

    /// Args: chunk 는 빈 줄로 나뉜 본문 한 덩어리다.
    /// Returns: 줄 순서대로의 블록. 목록 항목 아래 들여 쓴 줄은 그 항목에 이어 붙인다.
    /// Raises: 없음.
    public static func parse(_ chunk: String) -> [Block] {
        var out: [Block] = [], paragraph: [String] = [], items: [Item] = [], quote: [String] = []
        func flushParagraph() { if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        func flushList() { if !items.isEmpty { out.append(.list(items)); items = [] } }
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        for line in chunk.components(separatedBy: "\n") {
            if let groups = match(headingPattern, line) {
                flushParagraph(); flushList(); flushQuote()
                out.append(.heading(groups[1].count, groups[2]))
            } else if match(dividerPattern, line) != nil {
                flushParagraph(); flushList(); flushQuote()
                out.append(.divider)
            } else if let groups = match(quotePattern, line) {
                flushParagraph(); flushList()
                quote.append(groups[1])
            } else if let groups = match(itemPattern, line) {
                flushParagraph(); flushQuote()
                let indent = groups[1].reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let marker = groups[2].first?.isNumber == true ? groups[2] : "•"
                items.append(Item(level: min(3, indent / 2), marker: marker, text: groups[3]))
            } else if !items.isEmpty, line.first == " " || line.first == "\t", !line.trimmingCharacters(in: .whitespaces).isEmpty {
                items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
            } else {
                flushList(); flushQuote()
                paragraph.append(line)
            }
        }
        flushParagraph(); flushList(); flushQuote()
        return out
    }

    private static func match(_ pattern: NSRegularExpression, _ line: String) -> [String]? {
        guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
    }
}
