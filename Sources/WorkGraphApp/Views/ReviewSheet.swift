import SwiftUI
import WorkGraphCore

/// 정리 제안 시트: 종류별로 묶어 하나씩 고르고 [반영]. 처음엔 모두 골라 둔다. 안 고른 것은 다시 묻지 않는다
struct ReviewSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var selected: Set<Int64> = []
    @State private var opened: Set<ReviewProposal.Kind> = []        // '더 보기'로 펼친 묶음
    static let folded = 6                                           // 묶음마다 처음에 보여 주는 줄 수

    private var groups: [(kind: ReviewProposal.Kind, items: [ReviewProposal])] {
        ReviewProposal.Kind.allCases.compactMap { kind in
            let items = state.reviewProposals.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    /// 지금 시트에 보이는 제안 ('더 보기'로 펼치지 않은 묶음은 앞 몇 줄만)
    private var shown: Set<Int64> {
        Set(groups.flatMap { opened.contains($0.kind) ? $0.items : Array($0.items.prefix(Self.folded)) }.compactMap(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("정리 제안").font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink)
                Text("고른 것만 반영해요. 안 고른 것은 다시 묻지 않아요.").font(Brand.suit(12)).foregroundStyle(Brand.gray)
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(groups, id: \.kind) { group in section(group.kind, group.items) }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("나중에") { state.reviewSheetOpen = false }
                    .keyboardShortcut(.cancelAction).buttonStyle(BrandButtonStyle(kind: .secondary))
                Button("반영 (\(selected.intersection(shown).count))") { Task { await state.applyReview(selected: selected, shown: shown) } }
                    .keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle(kind: .primary))
                    .disabled(state.erasing)
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: 560, height: 560)
        .background(Color.white)
        .onAppear { selected = Set(state.reviewProposals.compactMap(\.id)) }
        .onChange(of: state.reviewProposals.compactMap(\.id)) { _, ids in selected = Set(ids); opened = [] }   // 제안이 바뀌면 다시 모두 고른다
        .alert("반영하지 못했어요", isPresented: Binding(get: { state.eraseError != nil }, set: { if !$0 { state.eraseError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(state.eraseError ?? "")
        }
    }

    private func section(_ kind: ReviewProposal.Kind, _ items: [ReviewProposal]) -> some View {
        let ids = Set(items.compactMap(\.id))
        let all = ids.isSubset(of: selected)
        let shown = opened.contains(kind) ? items : Array(items.prefix(Self.folded))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(AppState.reviewKindName(kind)).font(Brand.suit(13.5, .bold)).foregroundStyle(Brand.ink)
                Text("\(items.count)").font(Brand.suit(12, .medium)).foregroundStyle(Brand.gray)
                Spacer()
                Button(all ? "모두 빼기" : "모두 고르기") { if all { selected.subtract(ids) } else { selected.formUnion(ids) } }
                    .buttonStyle(.plain).font(Brand.suit(11.5)).foregroundStyle(Brand.tabText)
            }
            ForEach(shown) { proposal in row(proposal) }
            if items.count > shown.count {
                Button("\(items.count - shown.count)개 더 보기") { opened.insert(kind) }
                    .buttonStyle(.plain).font(Brand.suit(11.5)).foregroundStyle(Brand.tabText)
            }
        }
    }

    private func row(_ proposal: ReviewProposal) -> some View {
        let on = proposal.id.map(selected.contains) ?? false
        return Button {
            guard let id = proposal.id else { return }
            if on { selected.remove(id) } else { selected.insert(id) }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 13)).foregroundStyle(on ? Brand.ink : Brand.sub).padding(.top, 1)
                Text(proposal.summary).font(Brand.suit(12.5)).foregroundStyle(on ? Brand.text : Brand.gray).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 업무 목록 맨 위 한 줄: 대기 중인 정리 제안이 있으면 "✦ 정리 제안 12개  보기 ›"
struct ReviewBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if !state.reviewProposals.isEmpty {
            Button { state.reviewSheetOpen = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0x8A7566))
                    Text("정리 제안 \(state.reviewProposals.count)개").font(Brand.suit(12.5, .semibold)).foregroundStyle(Brand.ink)
                    Spacer(minLength: 4)
                    Text("보기 ›").font(Brand.suit(11.5)).foregroundStyle(Brand.gray)
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0xF4EFEA)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppState.reviewSummary(state.reviewProposals))
        }
    }
}
