import AppKit
import SwiftMath
import SwiftUI

/// 채팅 답의 LaTeX 수식. 문단을 글자·글줄 수식·블록 수식으로 나누고, 수식은 SwiftMath 로 그린 이미지로 보여 준다.
enum ChatMath {
    enum Segment: Equatable { case text(String), inline(String), block(String) }

    /// 한 문단 안의 줄: 글자와 글줄 수식이 이어진 것, 또는 가운데 블록 수식
    enum Line { case run([Segment]), block(String) }

    /// $$…$$·\[…\] = 블록, \(…\)·$…$ = 글줄 수식. 백틱 코드 안과 \$ 는 건드리지 않는다.
    /// $…$ 는 돈 표시와 헷갈리지 않게 여는 $ 바로 뒤와 닫는 $ 바로 앞이 공백이 아니고, 닫는 $ 바로 뒤가 숫자가 아닐 때만 수식이다.
    static func segments(_ value: String) -> [Segment] {
        let c = Array(value)
        var out: [Segment] = [], text = "", i = 0
        func starts(_ pattern: [Character], at k: Int) -> Bool { k + pattern.count <= c.count && Array(c[k..<k + pattern.count]) == pattern }
        func find(_ pattern: [Character], from k: Int) -> Int? {
            var j = k
            while j + pattern.count <= c.count { if starts(pattern, at: j) { return j }; j += 1 }
            return nil
        }
        /// k 에서 시작하는 수식: (조각, 다음 위치). 여는 표시만 있고 닫히지 않으면 그 표시까지 글자로
        func math(at k: Int) -> (Segment?, Int)? {
            for (open, close, block) in [("$$", "$$", true), ("\\[", "\\]", true), ("\\(", "\\)", false)] {
                let o = Array(open), e = Array(close)
                guard starts(o, at: k) else { continue }
                guard let end = find(e, from: k + o.count) else { return (nil, k + o.count) }
                let body = String(c[(k + o.count)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? (nil, end + e.count) : (block ? .block(body) : .inline(body), end + e.count)
            }
            guard c[k] == "$", k + 1 < c.count, !c[k + 1].isWhitespace else { return nil }
            var j = k + 1
            while let end = find(["$"], from: j) {
                if end > k + 1, !c[end - 1].isWhitespace, c[end - 1] != "\\", end + 1 >= c.count || !c[end + 1].isNumber {
                    return (.inline(String(c[(k + 1)..<end])), end + 1)
                }
                j = end + 1
            }
            return nil
        }
        while i < c.count {
            if c[i] == "`" {                                                 // 코드 조각: 같은 수의 백틱까지 그대로
                var n = 0
                while i + n < c.count, c[i + n] == "`" { n += 1 }
                let end = find(Array(repeating: "`", count: n), from: i + n).map { $0 + n } ?? i + n
                text += String(c[i..<end]); i = end
                continue
            }
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == "$" { text += "\\$"; i += 2; continue }
            if let (segment, next) = math(at: i) {
                if let segment {
                    if !text.isEmpty { out.append(.text(text)); text = "" }
                    out.append(segment)
                } else {
                    text += String(c[i..<next])
                }
                i = next
                continue
            }
            text.append(c[i]); i += 1
        }
        if !text.isEmpty { out.append(.text(text)) }
        return out
    }

    /// 조각을 줄로: 블록 수식은 따로, 그 사이 글자·글줄 수식은 한 줄로 잇는다 (블록 앞뒤 빈 줄은 뺀다)
    static func lines(_ segments: [Segment]) -> [Line] {
        var out: [Line] = [], run: [Segment] = []
        func flush() {
            var trimmed = run
            if case .text(let t)? = trimmed.first { trimmed[0] = .text(String(t.drop(while: \.isNewline))) }
            if case .text(let t)? = trimmed.last { trimmed[trimmed.count - 1] = .text(String(t.reversed().drop(while: \.isNewline).reversed())) }
            if trimmed.contains(where: { if case .text(let t) = $0 { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { return true } }) {
                out.append(.run(trimmed))
            }
            run = []
        }
        for segment in segments {
            if case .block(let latex) = segment { flush(); out.append(.block(latex)) } else { run.append(segment) }
        }
        flush()
        return out
    }

    struct Rendered {
        let image: NSImage
        /// 기준선 아래로 내려가는 높이 (글줄 수식을 글자 기준선에 맞출 때)
        let descent: CGFloat
    }

    private final class Box { let value: Rendered?; init(_ value: Rendered?) { self.value = value } }
    private static let cache = NSCache<NSString, Box>()

    /// LaTeX 를 이미지로. 수식 글꼴에 없는 글자(한글, ① 등)는 Apple SD Gothic Neo 로 채운다. 깨진 LaTeX 면 nil (원문을 보여 주게)
    @MainActor
    static func render(_ latex: String, display: Bool, fontSize: CGFloat = 15, color: NSColor = NSColor(Brand.tabText)) -> Rendered? {
        let key = "\(display)|\(fontSize)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.labelMode = display ? .display : .text
        label.textAlignment = .left
        let font = MTFontManager().latinModernFont(withSize: fontSize)
        font?.fallbackFont = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, fontSize, nil)
        label.font = font
        label.textColor = color
        label.latex = latex
        var result: Rendered?
        let size = label.sizeThatFits(.zero)
        if label.error == nil, size.width > 0, size.height > 0 {
            label.frame = CGRect(origin: .zero, size: size)
            label.layout()
            if let list = label.displayList, let image = NSImage(data: label.dataWithPDF(inside: label.bounds)) {
                result = Rendered(image: image, descent: list.descent)
            }
        }
        cache.setObject(Box(result), forKey: key)
        return result
    }
}

/// 블록 수식: 가운데 정렬, 넓으면 가로로 스크롤. 커서를 올리면 LaTeX 원문. 그리지 못하면 원문을 고정폭 글자로
struct ChatMathBlock: View {
    let latex: String

    var body: some View {
        if let rendered = ChatMath.render(latex, display: true, fontSize: 17) {
            ViewThatFits(in: .horizontal) {
                Image(nsImage: rendered.image).frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { Image(nsImage: rendered.image) }
            }
            .padding(.vertical, 4)
            .help(latex)
        } else {
            Text(verbatim: latex).font(.system(size: 12, design: .monospaced)).foregroundStyle(Brand.tabText)
        }
    }
}
