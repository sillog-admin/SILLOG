import SwiftUI
import SillogCore

/// 채팅 본문의 제목·문단·코드를 구분한다. 완성된 문서는 별도 미리보기로 제공한다.
struct ChatMessageText: View, Equatable {
    let text: String
    let sources: [ChatSource]
    let onSource: (ChatSource) -> Void

    // onSource is a new closure on every parent render but always opens the tapped source, so it is left out.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.sources.map(\.id) == rhs.sources.map(\.id)
    }

    private static let citationPattern = try! NSRegularExpression(pattern: #"\[((?:(?:node|observation|card|chat|conversation|message|library|file|git|gmail|drive|notion|digest|usage|recording|figma|slack|discord|higgsfield|canva|lovable):|https?://)[^\]\n]+)\]"#)

    /// Args: paragraph는 모델이 작성한 문단, sources는 실제로 조회한 근거이다.
    /// Returns: 식별자를 제거한 문단, 조회된 근거, 확인되지 않은 인용 여부.
    /// Raises: 없음.
    static func citations(in paragraph: String, sources: [ChatSource]) -> (String, [ChatSource], Bool) {
        let matches = citationPattern.matches(in: paragraph, range: NSRange(paragraph.startIndex..., in: paragraph))
        var body = paragraph
        var ids: [String] = []
        for match in matches.reversed() {
            guard let range = Range(match.range, in: body), let idRange = Range(match.range(at: 1), in: body) else { continue }
            ids.insert(String(body[idRange]), at: 0)
            body.removeSubrange(range)
        }
        let cited = ids.reduce(into: [ChatSource]()) { result, id in
            if let source = sources.first(where: { $0.id == id }), !result.contains(where: { $0.id == id }) { result.append(source) }
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), cited, ids.contains { id in !cited.contains(where: { $0.id == id }) })
    }

    /// Args: value는 코드 블록을 제외한 채팅 문단이다.
    /// Returns: 단일 물결표는 보존하고 명시적인 ~~취소선~~만 해석한 본문. 글줄 코드는 옅은 바탕의 고정폭 글자.
    /// Raises: 없음. Markdown 해석 실패 시 원문을 표시한다.
    static func inlineMarkdown(_ value: String) -> AttributedString {
        // Foundation은 ~ 하나도 취소선으로 해석한다. 코드·자동 링크·기존 이스케이프는 그대로 둔다.
        let tokens = try! NSRegularExpression(pattern: #"(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)|<[^>\n]+>|\\[\s\S]|~+"#)
        var escaped = value
        for match in tokens.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range, in: escaped), escaped[range] == "~" else { continue }
            escaped.replaceSubrange(range, with: #"\~"#)
        }
        guard var text = try? AttributedString(markdown: escaped, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return AttributedString(value) }
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].backgroundColor = Brand.chipSelectedFill
            text[run.range].font = .system(size: 14 * Brand.scale, design: .monospaced)
        }
        return text
    }

    /// 한 줄 글: 마크다운과 글줄 수식 (제목 줄에 쓴다)
    static func inlineText(_ value: String) -> Text {
        ChatMath.segments(value).reduce(Text("")) { $0 + piece($1) }
    }

    /// 글줄 조각: 글자는 마크다운, 글줄 수식은 기준선에 맞춘 이미지 (그리지 못하면 $원문$)
    static func piece(_ segment: ChatMath.Segment) -> Text {
        switch segment {
        case .text(let text): return Text(inlineMarkdown(text))
        case .inline(let latex):
            guard let rendered = ChatMath.render(latex, display: false, fontSize: 16 * Brand.scale) else { return Text(verbatim: "$\(latex)$") }
            return Text(Image(nsImage: rendered.image)).baselineOffset(-rendered.descent)
        case .block(let latex): return Text(verbatim: latex)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(ChatBlocks.parts(text).enumerated()), id: \.offset) { _, part in
                switch part {
                case .prose(let prose):
                    ForEach(Array(prose.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        ChatParagraph(text: paragraph, sources: sources, onSource: onSource).equatable()
                    }
                case .code(let language, let body, let closed):
                    ChatCodeBlock(language: language, code: body, closed: closed)
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One prose paragraph; equatable so streaming re-parses only the paragraph that changed.
private struct ChatParagraph: View, Equatable {
    let text: String
    let sources: [ChatSource]
    let onSource: (ChatSource) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.sources.map(\.id) == rhs.sources.map(\.id)
    }

    /// 문단: 수식이 없으면 그대로, 있으면 글줄(글자 + 글줄 수식 이미지)과 블록 수식을 차례로.
    /// 수식은 마크다운보다 먼저 떼어 낸다 (마크다운이 \[ 의 \ 와 행렬 줄바꿈 \\ 를 지워 LaTeX 가 깨진다)
    @ViewBuilder private func paragraphView(_ value: String, color: Color = Brand.tabText, lineSpacing: CGFloat = 9) -> some View {
        let segments = ChatMath.segments(value)
        if segments == [.text(value)] {
            bodyText(Text(ChatMessageText.inlineMarkdown(value)), color: color, lineSpacing: lineSpacing)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ChatMath.lines(segments).enumerated()), id: \.offset) { _, line in
                    switch line {
                    case .block(let latex): ChatMathBlock(latex: latex)
                    case .run(let run): bodyText(run.reduce(Text("")) { $0 + ChatMessageText.piece($1) }, color: color, lineSpacing: lineSpacing)
                    }
                }
            }
        }
    }

    private func bodyText(_ text: Text, color: Color = Brand.tabText, lineSpacing: CGFloat = 9) -> some View {
        text.font(Brand.font(.sectionTitle, .regular)).foregroundStyle(color).lineSpacing(lineSpacing)
    }

    /// 빈 줄 사이 덩어리 안의 블록을 차례로: 제목은 그 줄만, 목록은 글머리·번호에 매달린 들여쓰기, 인용은 왼쪽 세로줄, 구분선은 가는 가로줄
    @ViewBuilder private func blocksView(_ value: String) -> some View {
        let blocks = ChatBlocks.parse(value)
        if blocks == [.paragraph(value)] {
            paragraphView(value)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                    switch block {
                    case .heading(let level, let text):
                        ChatMessageText.inlineText(text).font(level == 1 ? Brand.font(.screenTitle, .semibold) : level == 2 ? Brand.font(.sectionTitle, .bold) : Brand.font(.sectionTitle, .semibold)).foregroundStyle(Brand.ink)
                            .padding(.top, offset == 0 ? 0 : 10)
                    case .paragraph(let text): paragraphView(text)
                    case .list(let items): listView(items)
                    case .quote(let text):
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Brand.line).frame(width: 3)
                            paragraphView(text, color: Brand.gray)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    case .divider:
                        Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 4)
                    }
                }
            }
        }
    }

    /// 목록: 글머리(단계마다 • ◦ ▪︎)나 번호를 같은 폭에 두고, 내용은 그 오른쪽에 매달려 줄이 넘어가도 들여쓰기가 맞는다
    private func listView(_ items: [ChatBlocks.Item]) -> some View {
        let numbered = items.contains { $0.marker != "•" }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.marker == "•" ? ["•", "◦", "▪︎", "▪︎"][min(item.level, 3)] : item.marker)
                        .font(Brand.font(.sectionTitle, .regular)).foregroundStyle(Brand.gray).monospacedDigit()
                        .frame(width: (numbered ? 24 : 12) * Brand.scale, alignment: .trailing)
                    paragraphView(item.text, lineSpacing: 7)
                }
                .padding(.leading, CGFloat(item.level) * 18)
            }
        }
    }

    var body: some View {
        let (value, cited, missing) = ChatMessageText.citations(in: text, sources: sources)
        if !value.isEmpty || !cited.isEmpty || missing {
            VStack(alignment: .leading, spacing: 6) {
                if let rows = ChatMarkdownTable.rows(in: value) {
                    ChatMarkdownTableView(rows: rows)
                } else if !value.isEmpty {
                    blocksView(value)
                }
                if !cited.isEmpty { ChatCitationButton(sources: cited, onSource: onSource) }
                if missing { Text(tr("확인되지 않은 근거")).font(Brand.font(.tag)).foregroundStyle(Brand.gray) }
            }
        }
    }
}

struct ChatCodeBlock: View {
    let language: String
    let code: String
    var closed = true
    @State private var copied = false
    @State private var diagramHeight: CGFloat = 160
    @State private var diagramFailed = false

    /// Draw only finished mermaid blocks; while streaming the source would fail to parse on every token.
    private var diagram: Bool { closed && !diagramFailed && language.lowercased() == "mermaid" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? tr("코드") : language).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? tr("복사됨") : tr("복사"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                        .padding(.horizontal, 6).frame(height: 22).hoverHighlight(cornerRadius: 5)
                }.buttonStyle(.plain).help(tr("코드 복사"))
            }
            .padding(.horizontal, 14).frame(height: 30)
            Rectangle().fill(Brand.line).frame(height: 1)
            if diagram {
                ChatMermaidView(code: code, height: $diagramHeight, failed: $diagramFailed)
                    .frame(height: diagramHeight)
                    .background(.white)
            } else {
                ScrollView(.horizontal) {
                    Text(code.trimmingCharacters(in: .newlines)).font(.system(size: 14 * Brand.scale, design: .monospaced)).foregroundStyle(Brand.tabText)
                        .lineSpacing(4)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
        }
        .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
    }
}

private struct ChatMarkdownTableView: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            CappedWidth(limit: 320 * Brand.scale) {
                                Text(ChatMessageText.inlineMarkdown(rows[row][column]))
                                    .font(Brand.font(.sectionTitle, row == 0 ? .semibold : .regular)).foregroundStyle(row == 0 ? Brand.ink : Brand.tabText)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(row == 0 ? ChatPalette.soft : .clear)
                        }
                    }
                    if row < rows.count - 1 { Rectangle().fill(Brand.line).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)   // header cells fill their row without stretching the table
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
        }
        .defaultScrollAnchor(.leading)
    }
}

/// Wraps its child at min(ideal width, limit). A width-capped frame alone lets the horizontal ScrollView measure one line, so the Grid row stays one line tall while the text wraps over the next row.
private struct CappedWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(.unspecified).width
        return subviews[0].sizeThatFits(ProposedViewSize(width: min(ideal, limit, proposal.width ?? .infinity), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: min(bounds.width, limit), height: nil))
    }
}

private struct ChatCitationButton: View {
    let sources: [ChatSource]
    let onSource: (ChatSource) -> Void
    @State private var showingSources = false

    static func chipTitle(_ stored: String) -> String {
        // Stored titles stay Korean for the model; only the chip follows the app language.
        let title = ChatRunner.displayTitle(stored)
        return title.count > 28 ? String(title.prefix(28)) + "…" : title
    }

    var body: some View {
        Button { showingSources = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.book.closed").font(.system(size: 9))
                Text(Self.chipTitle(sources[0].title)).lineLimit(1)
                if sources.count > 1 { Text("+\(sources.count - 1)").font(Brand.jost(10)) }
            }
            .font(Brand.font(.tag))
            .foregroundStyle(Brand.tabText)
            .padding(.horizontal, 7).frame(height: 26)
            .background(.white, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.line))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sources.count > 1 ? ChatRunner.displayTitle(sources[0].title) + tr(" 외 \(sources.count - 1)개") : ChatRunner.displayTitle(sources[0].title))
        .accessibilityHint(tr("출처 보기"))
        .popover(isPresented: $showingSources) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(tr("출처"))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sources) { source in
                            Button {
                                showingSources = false
                                onSource(source)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ChatRunner.displayTitle(source.title)).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                                    if !source.location.isEmpty {
                                        Text(source.location).font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1)
                                    }
                                    Text(source.excerpt).font(Brand.font(.caption)).foregroundStyle(Brand.tabText).lineLimit(4)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }.padding(16).frame(width: 320)
        }
    }
}
