import SwiftUI

/// 쪽 번호 ‹ 1 2 3 › (파일 > 지난 기록). 쪽이 많으면 처음·끝과 지금 쪽 앞뒤만 보이고 사이는 …
struct PageNumbers: View {
    /// 지금 쪽 (0부터)
    let current: Int
    let pages: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            arrow("chevron.left", label: "이전 쪽", to: current - 1)
            ForEach(Array(Self.numbers(current: current, pages: pages).enumerated()), id: \.offset) { _, page in
                if let page {
                    Button { select(page) } label: {
                        Text("\(page + 1)").font(Brand.jost(12)).foregroundStyle(page == current ? Brand.ink : Brand.gray)
                            .frame(minWidth: 28, minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(page == current ? Brand.paper : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hoverHighlight(cornerRadius: 6, active: page != current)
                    .accessibilityLabel("\(page + 1)쪽")
                } else {
                    Text("…").font(Brand.jost(12)).foregroundStyle(Brand.gray).frame(width: 20)
                }
            }
            arrow("chevron.right", label: "다음 쪽", to: current + 1)
        }
    }

    private func arrow(_ symbol: String, label: String, to page: Int) -> some View {
        let enabled = (0..<pages).contains(page)
        return Button { select(page) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? Brand.tabText : Brand.sub).disabled(!enabled)
        .hoverHighlight(cornerRadius: 6, active: enabled)
        .accessibilityLabel(label)
    }

    /// 보여 줄 쪽 (0부터). nil 은 '…'. 7쪽까지는 전부, 더 많으면 처음·끝과 지금 쪽 앞뒤 하나 (끝 가까이에서는 다섯 칸을 채운다)
    static func numbers(current: Int, pages: Int) -> [Int?] {
        guard pages > 7 else { return Array(0..<max(pages, 0)) }
        var shown: Set<Int> = [0, pages - 1, current - 1, current, current + 1]
        if current <= 2 { shown.formUnion([1, 2, 3]) }
        if current >= pages - 3 { shown.formUnion([pages - 4, pages - 3, pages - 2]) }
        var result: [Int?] = [], previous: Int?
        for page in shown.filter({ (0..<pages).contains($0) }).sorted() {
            if let previous, page - previous == 2 { result.append(previous + 1) }    // 한 쪽만 빠지면 … 대신 그 번호
            else if let previous, page - previous > 2 { result.append(nil) }
            result.append(page)
            previous = page
        }
        return result
    }
}
