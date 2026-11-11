import SwiftUI
import SillogCore

/// 업무 드로어 자리에 띄우는 노드 상세 (분야·세션·자료·앱·주제·문제·나중에 할 일 등). 업무 상세와 같은 머리 모양,
/// 아래는 사실 몇 줄과 연결된 노드 묶음. 연결된 노드를 누르면 그 노드 상세로 넘어가고(업무는 업무 상세로), 맨 아래에 지우기
struct NodeDetailView: View {
    @EnvironmentObject private var state: AppState
    let ref: NodeRef
    @State private var detail: NodeDetail?

    private static let when: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = tr("M월 d일 HH:mm"); return f
    }()

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else {
                VStack(spacing: 8) {
                    Text(tr("이 노드를 찾지 못했어요")).font(Brand.suit(17, .medium)).foregroundStyle(Brand.ink)
                    Text(tr("지웠거나 그래프를 다시 만들었을 수 있어요.")).font(Brand.suit(12)).foregroundStyle(Brand.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: ref) { _, _ in reload() }
        .onChange(of: state.graphVersion) { _, _ in reload() }
    }

    private func reload() { detail = state.nodeDetail(ref) }

    private func content(_ d: NodeDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(d)
                .padding(.horizontal, 33).padding(.top, state.nodeTrail.isEmpty ? 30 : 16).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !d.facts.isEmpty { facts(d.facts) }
                    if !d.notes.isEmpty {
                        sectionTitle(tr("한 일"), count: nil)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(d.notes.enumerated()), id: \.offset) { _, note in
                                Text("· " + note).font(Brand.suit(12.5)).foregroundStyle(Brand.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.bottom, 22)
                    }
                    ForEach(d.sections, id: \.title) { section in
                        sectionTitle(section.title, count: section.total)
                        VStack(spacing: 0) { ForEach(section.links) { row($0) } }
                        if section.total > section.links.count {
                            Text(tr("외 \(section.total - section.links.count)개")).font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.top, 6)
                        }
                        Spacer().frame(height: 22)
                    }
                    if d.erasable { eraseButton(d).padding(.top, 18) }
                }
                .padding(.horizontal, 33).padding(.bottom, 24)
            }
        }
    }

    private func header(_ d: NodeDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.nodeTrail.isEmpty {
                Button { state.backNode() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text(tr("뒤로")).font(Brand.suit(12))
                    }
                    .foregroundStyle(Brand.tabText).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.bottom, 12)
            }
            BrandBadge(d.kindName)
            Text(d.title).font(Brand.suit(24, .semibold)).tracking(-1).foregroundStyle(Brand.ink).lineLimit(3).padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
            if let address = d.address, address != d.title {
                Text(address).font(Brand.suit(11.5)).foregroundStyle(Brand.gray).lineLimit(2).truncationMode(.middle).textSelection(.enabled).padding(.top, 6)
            }
            if d.openable || d.resumable {
                HStack(spacing: 8) {
                    if d.openable {
                        Button { open(d) } label: {
                            HStack(spacing: 6) { Image(systemName: "arrow.up.right.square").font(.system(size: 12)); Text(d.label == NodeLabel.app ? tr("앱 열기") : tr("열기")) }
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(BrandButtonStyle(kind: .primary))
                    }
                    if d.resumable {
                        Button { state.prepareResume(label: d.label, key: d.key) } label: {
                            HStack(spacing: 7) { Image(systemName: "arrow.counterclockwise").font(.system(size: 12)); Text(tr("다시 열기")) }.padding(.horizontal, 6)
                        }
                        .buttonStyle(BrandButtonStyle(kind: .primary))
                    }
                }
                .padding(.top, 16)
            }
        }
    }

    private func open(_ d: NodeDetail) {
        if d.label == NodeLabel.app { state.openApp(bundle: d.key) } else { state.openGraphItem(uri: d.key) }
    }

    private func facts(_ facts: [NodeDetail.Fact]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.name).font(Brand.suit(12)).foregroundStyle(Brand.gray)
                    Text(Self.text(fact.value)).font(Brand.suit(12.5, .medium)).foregroundStyle(Brand.text)
                }
            }
        }
        .padding(.bottom, 26)
    }

    static func text(_ value: NodeDetail.Value) -> String {
        switch value {
        case .text(let text): text
        case .duration(let seconds): TasksView.duration(seconds)
        case .time(let ts): when.string(from: Date(timeIntervalSince1970: ts))
        case .count(let n): tr("\(n)개")
        }
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Brand.suit(13, .bold)).foregroundStyle(Brand.ink)
            if let count { Text("\(count)").font(Brand.suit(11.5, .medium)).foregroundStyle(Brand.gray) }
        }
        .padding(.bottom, 8)
    }

    /// 연결된 노드 한 줄: 이름, 오른쪽에 시간이나 날짜. 누르면 그 노드 상세
    private func row(_ link: NodeDetail.Link) -> some View {
        Button { state.openNodeDetail(NodeRef(label: link.label, key: link.key), fromDetail: true) } label: {
            HStack(spacing: 8) {
                Text(link.title).font(Brand.suit(12.5)).foregroundStyle(Brand.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let meta = Self.meta(link) { Text(meta).font(Brand.suit(11)).foregroundStyle(Brand.gray).fixedSize() }
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
    }

    static func meta(_ link: NodeDetail.Link) -> String? {
        if let seconds = link.seconds, seconds >= 1, link.label != NodeLabel.session { return TasksView.duration(seconds) }
        if let at = link.at { return when.string(from: Date(timeIntervalSince1970: at)) }
        return nil
    }

    private func eraseButton(_ d: NodeDetail) -> some View {
        Button { state.askErase(ref) } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash").font(.system(size: 11))
                Text(tr("이 노드 지우기")).font(Brand.suit(12))
            }
            .foregroundStyle(Color(hex: 0xC0573F))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.erasing)
        .help(tr("이 노드와 이 노드에서만 이어진 노드, 이 노드가 찍힌 원시 기록을 지워요. 되돌릴 수 없어요"))
    }
}

/// 지우기 확인 창 하나 (그래프 우클릭, 업무·노드 상세의 지우기 단추가 함께 쓴다)
struct EraseDialog: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        let ask = state.eraseAsk
        let title = ask.map { tr("'\($0.report.title)'\(EraseCopy.object($0.report.title)) 지울까요?") } ?? ""
        return content.confirmationDialog(title, isPresented: Binding(get: { state.eraseAsk != nil }, set: { if !$0 { state.eraseAsk = nil } }),
                                          titleVisibility: .visible, presenting: ask) { ask in
            Button(ask.ref.label == NodeLabel.task ? tr("이 업무 지우기") : tr("지우기"), role: .destructive) { Task { await state.erase(ask.ref) } }
            if ask.ref.label == NodeLabel.app {
                Button(tr("지우고 앞으로도 기록 안 함"), role: .destructive) { Task { await state.erase(ask.ref, excludeApp: true) } }
            }
            if let theme = ask.theme {
                Button(tr("'\(theme.title)' 분야째 지우기 (업무 \(theme.tasks)개)"), role: .destructive) {
                    Task { await state.erase(NodeRef(label: NodeLabel.theme, key: theme.key)) }
                }
            }
            Button(tr("취소"), role: .cancel) {}
        } message: { ask in
            Text(EraseCopy.message(label: ask.ref.label, ask.report))
        }
        .alert(tr("지우지 못했어요"), isPresented: Binding(get: { state.eraseError != nil }, set: { if !$0 { state.eraseError = nil } })) {
            Button(tr("확인"), role: .cancel) {}
        } message: {
            Text(state.eraseError ?? "")
        }
    }
}
