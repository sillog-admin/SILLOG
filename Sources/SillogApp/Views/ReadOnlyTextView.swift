import AppKit
import SwiftUI

/// 긴 텍스트(화면 텍스트 전문, 프롬프트, 응답) 표시용. SwiftUI Text 는 수천 자에 선택까지 켜면 느려서 NSTextView 를 쓴다.
/// 기본은 SUIT 11 회색 1.5배 줄 간격(Figma 원문 상자), monospaced 는 JSON 같은 코드형 본문.
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    var monospaced = false

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 9)
        textView.font = monospaced
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : (NSFont(name: "SUIT-Regular", size: 11) ?? .systemFont(ofSize: 11))
        textView.textColor = NSColor(monospaced ? Brand.tabText : Brand.gray)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = monospaced ? 1.65 : 1.4
        textView.defaultParagraphStyle = paragraph
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scroll(.zero)
    }
}

/// 상세 안에서 쓰는 고정 높이 텍스트 상자: 회색 12 제목, 옅은 회색 바탕 모서리 6.
struct TextBlock: View {
    let title: String
    let text: String
    var height: CGFloat = 220
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Brand.suit(12)).foregroundStyle(Brand.gray)
            ReadOnlyTextView(text: text, monospaced: monospaced)
                .frame(height: min(height, CGFloat(max(3, text.split(whereSeparator: \.isNewline).count + 1)) * 17 + 18))
                .background(RoundedRectangle(cornerRadius: 6).fill(Brand.paper))
        }
    }
}
