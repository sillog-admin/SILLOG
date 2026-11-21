import SwiftUI
import SillogCore

/// 192x156 결과물 카드. 새 대화 화면도 쓴다
struct ChatResultCard: View {
    @ObservedObject var library: LibraryState
    let item: ChatLibraryItem
    var onOpen: (ChatLibraryItem) -> Void
    @State private var first = ""
    private var versions: Int { library.versionCounts[item.id] ?? 1 }

    var body: some View {
        Button { onOpen(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(Brand.font(.tag, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                    Text(first).font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(4)   // 앞부분 본문으로 칸을 채운다 (첫 줄만 두면 머리말 한 줄만 보여 비었다)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).padding(.top, 10)
                    .frame(width: 164, height: 86, alignment: .topLeading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line, lineWidth: 1))
                Text(item.title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink).lineLimit(1).padding(.top, 12)
                Text(ChatDateText.relative(item.createdAt) + (versions > 1 ? "  ·  " + tr("버전 \(versions)개") : "")).font(Brand.font(.tag)).foregroundStyle(Brand.gray).padding(.top, 4)
            }.padding(13).frame(width: 192, height: 156, alignment: .topLeading)
                .background(Brand.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ChatPalette.cardLine, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .task(id: item.id) {
                let info = LibraryTextInfo.from((try? library.store.text(for: item.id)) ?? "")
                first = info.lead.split(separator: "\n").filter { $0 != item.title }.joined(separator: "\n")   // 제목과 같은 줄은 빼고
            }
    }
}
