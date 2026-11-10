import SwiftUI
import WorkGraphCore

/// 192x156 결과물 카드. 새 대화 화면도 쓴다
struct ChatResultCard: View {
    @ObservedObject var library: LibraryState
    let item: ChatLibraryItem
    var onOpen: (ChatLibraryItem) -> Void
    @State private var first = ""

    var body: some View {
        Button { onOpen(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(Brand.suit(9, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                    Text(first).font(Brand.suit(7)).foregroundStyle(Brand.gray).lineLimit(2)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).padding(.top, 10)
                    .frame(width: 164, height: 86, alignment: .topLeading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line, lineWidth: 1))
                Text(item.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink).lineLimit(1).padding(.top, 12)
                Text(ChatDateText.relative(item.createdAt)).font(Brand.suit(10)).foregroundStyle(Brand.gray).padding(.top, 4)
            }.padding(13).frame(width: 192, height: 156, alignment: .topLeading)
                .background(Brand.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ChatPalette.cardLine, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .task(id: item.id) { first = LibraryTextInfo.read(library.store.url(for: item)).first }
    }
}
