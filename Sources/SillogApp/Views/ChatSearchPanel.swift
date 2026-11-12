import SwiftUI
import SillogCore

/// 대화 검색 창 본체 (Figma CH-41~43). 어둡게 하는 덮개와 위치는 바깥에서 정한다.
struct ChatSearchPanel: View {
    @ObservedObject var chat: ChatState
    var onOpen: (ChatConversation) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var hits: [ChatSearchHit] = []
    /// hits를 만든 검색어. 디바운스 중에는 '맞는 대화가 없어요'를 띄우지 않는다.
    @State private var searched = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 검색어가 없을 때는 최근 대화 앞 8개를 같은 모양으로 보인다.
    private var rows: [ChatSearchHit] {
        trimmed.isEmpty ? chat.conversations.prefix(8).map {
            ChatSearchHit(conversationID: $0.id, title: $0.title, snippet: "", updatedAt: $0.updatedAt)
        } : hits
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Brand.gray)
                TextField("", text: $query, prompt: Text(tr("대화 검색")).font(Brand.font(.body)).foregroundColor(Brand.gray))
                    .textFieldStyle(.plain).font(Brand.font(.body)).foregroundStyle(Brand.text).focused($focused)
                    .onSubmit(openSelected)
            }.padding(.horizontal, 20).frame(height: 48)
            if !rows.isEmpty || !trimmed.isEmpty {
                Rectangle().fill(ChatPalette.cardLine).frame(height: 1)
                results.padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ChatPalette.panelLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 6)
        .onAppear { focused = true }
        .task(id: trimmed) {
            index = 0
            guard !trimmed.isEmpty else { hits = []; searched = ""; return }
            try? await Task.sleep(for: .milliseconds(200))      // 한 글자씩 칠 때마다 DB를 훑지 않게, 앞 검색은 취소된다
            await refresh()
        }
        .onChange(of: chat.conversations.map { "\($0.id)\u{1}\($0.title)" }) { _, _ in   // 제목이 바뀌거나 대화가 지워지면 다시 찾는다
            Task { await refresh() }
        }
        .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
        .onKeyPress(.downArrow) { index = min(max(rows.count - 1, 0), index + 1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    @ViewBuilder private var results: some View {
        if rows.isEmpty {
            VStack(spacing: 4) {
                Text(tr("‘\(trimmed)’\(Self.particle(trimmed)) 맞는 대화가 없어요.")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                Text(tr("대화 제목과 메시지 내용에서 찾아요.")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
            }.frame(maxWidth: .infinity).padding(.vertical, 36).opacity(searched == trimmed ? 1 : 0)
        } else {
            Text(trimmed.isEmpty ? tr("최근") : tr("대화 \(rows.count)개")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                .padding(.top, 12).padding(.bottom, 6).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, hit in row(hit, selected: i == index) }
                }
            }.frame(maxHeight: 360)
        }
    }

    private func row(_ hit: ChatSearchHit, selected: Bool) -> some View {
        Button { open(hit) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left").font(.system(size: 14)).foregroundStyle(Brand.tabText).frame(width: 16, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        HoverScrollingText(text: ChatConversation.display(hit.title)).font(Brand.font(.body)).foregroundStyle(Brand.ink)
                        Spacer(minLength: 8)
                        Text(ChatDateText.day(hit.updatedAt)).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                    }
                    if !hit.snippet.isEmpty {
                        Text(highlighted(hit.snippet.replacingOccurrences(of: "\n", with: " "))).font(Brand.font(.caption)).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9).frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? ChatPalette.rowHover : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .onHover { if $0, let i = rows.firstIndex(where: { $0.id == hit.id }) { index = i } }
    }

    /// 맞은 글자만 진하게 보인다.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = Brand.gray
        var from = out.startIndex
        while !trimmed.isEmpty, from < out.endIndex,
              let r = out[from...].range(of: trimmed, options: .caseInsensitive) {
            out[r].foregroundColor = Brand.ink
            out[r].font = Brand.font(.caption, .medium)
            from = r.upperBound
        }
        return out
    }

    private func refresh() async {
        let q = trimmed
        guard !q.isEmpty, !Task.isCancelled else { return }
        let found = await chat.search(q)
        guard !Task.isCancelled, q == trimmed else { return }
        hits = found; searched = q
        index = min(index, max(found.count - 1, 0))
    }

    /// 마지막 글자에 받침이 있으면 '과', 없으면 '와'. 한글이 아니라 판정할 수 없으면 Figma(CH-43)와 같은 '과'.
    static func particle(_ word: String) -> String {
        guard let v = word.unicodeScalars.last?.value, (0xAC00...0xD7A3).contains(v) else { return tr("과") }
        return (v - 0xAC00) % 28 == 0 ? tr("와") : tr("과")
    }

    private func openSelected() { if rows.indices.contains(index) { open(rows[index]) } }
    private func open(_ hit: ChatSearchHit) {
        if let c = chat.conversations.first(where: { $0.id == hit.conversationID }) { onOpen(c) }
        else { hits.removeAll { $0.conversationID == hit.conversationID } }     // 그새 지워진 대화
    }
}
