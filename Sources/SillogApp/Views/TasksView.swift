import SwiftUI
import SillogCore

/// 업무: 왼쪽 업무 트리(분야 폴더 안에 업무), 오른쪽 업무 상세(세션 목록과 다시 열기). Figma 참고 TK-01, TK-02, TK-W1.
/// 창에서는 업무 패널(TasksPanel)이 목록만 보이다가 업무를 고르면 상세까지 펼친다
struct TasksView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedTask: Int64?
    @State private var collapsed: Set<String> = []          // 접은 분야 폴더
    @State private var fieldFilter: Set<String> = []        // 분야 막대에서 고른 분야들 (다시 누르면 빠짐, 비면 전체)
    @State private var rowFrames: [Int64: CGRect] = [:]     // 업무 줄 위치(목록 좌표). 고른 줄 상자를 옮기는 데 씀
    @State private var boxTop: CGFloat = 0                  // 고른 줄 상자 위 모서리. 위아래를 따로 움직여 물방울처럼 늘었다 모임
    @State private var boxBottom: CGFloat = 0
    @State private var boxX = CGRect.zero                   // 가로 위치와 폭(줄마다 같음)
    @State private var sessions: [SessionSummary] = []
    @State private var digests: [Digest] = []
    @State private var tab: DetailTab
    @State private var materials = TaskMaterials()
    @State private var openKinds: Set<String> = []          // 자료 탭에서 '더 보기'로 펼친 종류
    @State private var editing: Digest?
    /// 목록에서 업무를 눌렀을 때 (업무 패널이 상세를 펼친다)
    private let onSelect: (Int64) -> Void
    /// 목록 옆에 상세를 그릴지. 업무 패널이 접혀 있으면 목록만 (안 보이는 상세가 옆 본문의 클릭을 가로채지 않게)
    private let showsDetail: Bool

    /// 상세의 탭: 작업 세션, 요약(주간·월간), 자료(그래프 업무 팝업과 같은 종류별 자료와 같은 맥락 업무)
    enum DetailTab { case sessions, digests, materials }

    /// 스냅샷용: 고른 업무와 탭으로 시작
    init(selectedTask: Int64? = nil, tab: DetailTab = .sessions, showsDetail: Bool = true, onSelect: @escaping (Int64) -> Void = { _ in }) {
        _selectedTask = State(initialValue: selectedTask)
        _tab = State(initialValue: tab)
        self.showsDetail = showsDetail
        self.onSelect = onSelect
    }

    /// Built per use: the language can change while the app runs.
    private static var day: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.current.rawValue)
        formatter.dateFormat = tr("M월 d일")
        return formatter
    }
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 277)
            if showsDetail {
                Group {
                    if let node = state.openNode {
                        NodeDetailView(ref: node)                        // 그래프에서 업무가 아닌 노드를 눌렀을 때
                    } else if state.taskList.isEmpty {
                        emptyState
                    } else if let task = state.taskList.first(where: { $0.id == selectedTask }) {
                        detail(task)
                    } else {
                        placeholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white)
            }
        }
        .onAppear {
            if let id = state.selectedTaskId { selectedTask = id }        // 그래프에서 고른 업무로 시작
            state.refreshTasks(); reload()
        }
        .onChange(of: state.selectedTaskId) { _, id in if let id, id != selectedTask { selectedTask = id } }   // 그래프, 같은 맥락 업무에서 고를 때
        .onChange(of: selectedTask) { _, id in openKinds = []; reload(); moveBox(to: id) }
        .onChange(of: state.graphVersion) { _, _ in reload() }
        .sheet(item: $editing) { digest in
            DigestEditSheet(digest: digest) { body in
                if let id = digest.id { state.editDigest(id: id, body: body) }
                editing = nil
                reload()
            } cancel: { editing = nil }
        }
    }

    // MARK: 왼쪽 목록 (분야 폴더 안에 업무, 파일 트리처럼)

    struct TaskFolder: Identifiable, Equatable {
        let name: String
        let tasks: [TaskSummary]
        var id: String { name }
        var seconds: Double { tasks.reduce(0) { $0 + $1.activeSeconds } }
    }

    // Field and type names are stored Korean values; translate only when drawing.
    static let noField = "분야 없음"

    /// 분야별 폴더: 최근에 일한 분야가 위, '분야 없음' 은 늘 맨 아래. 폴더 안은 받은 순서(최근 활동 순) 그대로
    static func folders(_ tasks: [TaskSummary]) -> [TaskFolder] {
        var order: [String] = [], groups: [String: [TaskSummary]] = [:]
        for task in tasks {
            let name = task.theme ?? noField
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(task)
        }
        let latest = { (name: String) in groups[name]?.map(\.lastActive).max() ?? 0 }
        return order.sorted { a, b in
            if (a == noField) != (b == noField) { return b == noField }
            return latest(a) > latest(b)
        }
        .map { TaskFolder(name: $0, tasks: groups[$0] ?? []) }
    }

    // MARK: 분야 막대 (분야 색은 그래프 index.html 의 FIELD_COLORS, SPARE_COLORS 와 같은 벌)

    struct FieldStat: Identifiable, Equatable {
        let name: String
        let count: Int
        let color: Color
        var id: String { name }
        var title: String { L10n.tr(key: name) }
    }

    private static let fieldColors: [String: UInt32] = [
        "산출물작성": 0x4A86C5, "정보수집": 0xE9B23F, "학습": 0xE0533D, "행정처리": 0x8A4E7D, "커뮤니케이션": 0x3D9B6B, "반복작업": 0x6E9F8F,
    ]
    private static let spareColors: [UInt32] = [0x9C4A35, 0x2E4D8F]
    private static let etc = "기타"

    /// 분야별 업무 수와 색. 그래프와 같은 순서: 이름 있는 분야 먼저, 많은 순, 예비색은 그 순서대로. '기타', '분야 없음' 은 맨 끝
    static func fieldStats(_ tasks: [TaskSummary]) -> [FieldStat] {
        var counts: [String: Int] = [:]
        for task in tasks { counts[task.field ?? noField, default: 0] += 1 }
        return fieldStats(counts: counts)
    }

    /// 분야 이름별 개수로 같은 규칙의 색과 순서를 만든다 (보관함 홈도 씀)
    static func fieldStats(counts: [String: Int]) -> [FieldStat] {
        let named = counts.keys.filter { $0 != etc && $0 != noField }
            .sorted { a, b in
                let known = (fieldColors[a] != nil, fieldColors[b] != nil)
                return known.0 != known.1 ? known.0 : (counts[a] ?? 0, b) > (counts[b] ?? 0, a)
            }
        var spare = 0
        var stats = named.map { name -> FieldStat in
            var hex: UInt32 = 0xB9B3AE
            if let known = fieldColors[name] { hex = known } else if spare < spareColors.count { hex = spareColors[spare]; spare += 1 }
            return FieldStat(name: name, count: counts[name] ?? 0, color: Color(hex: hex))
        }
        if let n = counts[etc] { stats.append(FieldStat(name: etc, count: n, color: Color(hex: 0x9B9490))) }
        if let n = counts[noField] { stats.append(FieldStat(name: noField, count: n, color: Color(hex: 0xB9B3AE))) }
        return stats
    }

    private var sidebar: some View {
        let fields = Self.fieldStats(state.taskList)
        let filter = fieldFilter.intersection(fields.map(\.name))                              // 그 분야 업무가 없어졌으면 무시
        let shown = filter.isEmpty ? state.taskList : state.taskList.filter { filter.contains($0.field ?? Self.noField) }   // 받은 순서(최근 활동 순) 그대로
        let colors = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.color) })
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(tr("업무")).font(Brand.font(.screenTitle)).tracking(-0.8).foregroundStyle(Brand.ink)
                    Text("\(state.taskList.count)").font(Brand.font(.sectionTitle)).foregroundStyle(Brand.gray)
                }
                if !fields.isEmpty { fieldBar(fields, filter: filter) }
                ReviewBanner()                                              // 정리 제안이 있으면 한 줄
            }
            .padding(.horizontal, 27).padding(.top, 27).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if state.taskList.isEmpty {
                // 창에서는 상세가 접혀 있어 오른쪽 빈 화면 안내가 안 보이므로 목록에도 한 줄
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("아직 업무가 없어요")).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
                    Text(tr("활동이 쌓여 정리되면 업무가 여기에 모여요.")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 27)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shown) { task in taskRow(task, color: colors[task.field ?? Self.noField] ?? Brand.sub) }
                    }
                    .coordinateSpace(name: "taskList")
                    .background(alignment: .topLeading) {                                     // 고른 줄: 연한 상자 하나가 줄 사이를 옮겨 다님
                        if boxBottom > boxTop {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0xECE6E0))
                                .frame(width: boxX.width, height: boxBottom - boxTop).offset(x: boxX.minX, y: boxTop)
                        }
                    }
                    .onPreferenceChange(RowFrameKey.self) { frames in rowFrames = frames; snapBox() }
                    .backgroundPreferenceValue(TimelineDotKey.self) { dots in timelineSpine(dots) }   // 점들을 잇는 점선
                    .padding(.bottom, 16)
                }
                .thinScrollLight()
            }
        }
        .background(Brand.paper)                                                         // 업무 목록 바탕: 아이콘 줄과 본문 사이 톤
    }

    private func toggleField(_ name: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            if fieldFilter.contains(name) { fieldFilter.remove(name) } else { fieldFilter.insert(name) }
        }
    }

    /// 분야 비율 막대: 분야마다 업무 수에 비례한 둥근 조각. 누르면 넣고 빼며(여러 개), 고른 분야는 아래로 늘어나 종류 나무가 펼쳐진다
    private func fieldBar(_ fields: [FieldStat], filter: Set<String>) -> some View {
        let sel = fields.filter { filter.contains($0.name) }
        let rows = sel.map { Self.typeRows(state.taskList, field: $0.name) }
        let longest = rows.map(\.count).max() ?? 1
        let treeH: CGFloat = 46 + CGFloat(max(longest, 1) - 1) * 26 + 14
        return GeometryReader { geo in
            let total = CGFloat(fields.reduce(0) { $0 + $1.count })
            let room = geo.size.width - 3 * CGFloat(fields.count - 1)
            let widths = fields.map { max(8, room * CGFloat($0.count) / total) }
            let starts: [CGFloat] = widths.indices.map { i in widths[..<i].reduce(CGFloat(0), +) + 3 * CGFloat(i) }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 3) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { i, field in
                        let on = filter.contains(field.name)
                        Button {
                            toggleField(field.name)
                        } label: {
                            RoundedRectangle(cornerRadius: 4).fill(field.color)
                                .opacity(filter.isEmpty || on ? 1 : 0.28)
                                .frame(width: widths[i], height: 8)
                                .contentShape(Rectangle().inset(by: -4))
                        }
                        .buttonStyle(.plain)
                        .help(tr("\(field.title) \(field.count)개"))
                        .accessibilityLabel(tr("\(field.title) 분야, 업무 \(field.count)개, \(on ? tr("골라짐") : tr("안 골라짐"))"))
                    }
                }
                if sel.isEmpty {
                    Text(tr("막대를 누르면 종류가 펼쳐져요. 여러 개 고를 수 있어요."))
                        .font(Brand.font(.tag)).foregroundStyle(Color(hex: 0x8C837C)).lineLimit(1)
                        .offset(y: 16)
                }
                ForEach(Array(sel.enumerated()), id: \.element.id) { k, field in
                    let i = fields.firstIndex { $0.id == field.id } ?? 0
                    let colW = geo.size.width / CGFloat(sel.count)
                    let left = CGFloat(k) * colW
                    fieldTree(field, rows: rows[k], a: starts[i], b: starts[i] + widths[i], left: left, colW: colW)
                        .offset(y: 8)
                        .transition(.scale(scale: 0.01, anchor: .top).combined(with: .opacity))
                }
            }
        }
        .frame(height: 8 + (sel.isEmpty ? 22 : treeH))
    }

    /// 그 분야 업무의 종류별 개수: 많은 순, 최대 4개, 넘치면 마지막에 "외 N". 종류가 비었거나 분야와 같으면 세지 않는다
    static func typeRows(_ tasks: [TaskSummary], field: String) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for t in tasks where (t.field ?? noField) == field {
            if let type = t.taskType, !type.isEmpty, type != field { counts[type, default: 0] += 1 }
        }
        let sorted = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var rows = sorted.prefix(4).map { ($0.key, $0.value) }
        if sorted.count > 4 { rows.append((tr("외 \(sorted.count - 4)"), sorted.dropFirst(4).reduce(0) { $0 + $1.value })) }
        return rows
    }

    /// 막대 조각(a..b) 아래로 늘어난 목과 동그라미, 종류 가지와 알약. 좌표는 막대 아래 끝이 y=0
    private func fieldTree(_ field: FieldStat, rows: [(String, Int)], a: CGFloat, b: CGFloat, left: CGFloat, colW: CGFloat) -> some View {
        let cx = max(a + 12, left + 12)
        let avail = max(20, left + colW - (cx + 14) - 4)
        let count = TasksView.fieldCount(state.taskList, field.name)
        let lastY = 46 + CGFloat(max(rows.count, 1) - 1) * 26
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: a, y: -2))
                p.addCurve(to: CGPoint(x: cx - 6, y: 18), control1: CGPoint(x: a, y: 9), control2: CGPoint(x: cx - 7, y: 8))
                p.addLine(to: CGPoint(x: cx + 6, y: 18))
                p.addCurve(to: CGPoint(x: b, y: -2), control1: CGPoint(x: cx + 7, y: 8), control2: CGPoint(x: b, y: 9))
                p.closeSubpath()
            }.fill(field.color)
                .onTapGesture { toggleField(field.name) }     // 늘어난 목이 막대를 덮으므로 여기를 눌러도 접힌다
            Circle().fill(field.color).frame(width: 22, height: 22).offset(x: cx - 11, y: 15)
                .onTapGesture { toggleField(field.name) }
            Text("\(count)").font(Brand.font(.tag, .bold)).foregroundStyle(.white).offset(x: cx - 11, y: 15).frame(width: 22, height: 22)
                .allowsHitTesting(false)
            if !rows.isEmpty {
                Path { p in
                    p.move(to: CGPoint(x: cx, y: 37))
                    p.addLine(to: CGPoint(x: cx, y: lastY - 6))
                    p.addQuadCurve(to: CGPoint(x: cx + 6, y: lastY), control: CGPoint(x: cx, y: lastY))
                    p.addLine(to: CGPoint(x: cx + 12, y: lastY))
                    for i in 0..<(rows.count - 1) {
                        let y = 46 + CGFloat(i) * 26
                        p.move(to: CGPoint(x: cx, y: y)); p.addLine(to: CGPoint(x: cx + 12, y: y))
                    }
                }
                .stroke(field.color.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 5) {
                    Text(L10n.tr(key: row.0)).font(Brand.font(.caption, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                    Text("\(row.1)").font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineLimit(1)
                }
                .padding(.vertical, 3).padding(.horizontal, 9)
                .background(Capsule().fill(field.color.opacity(0.13)))
                .frame(maxWidth: avail, alignment: .leading)
                .frame(height: 20)
                .offset(x: cx + 14, y: 46 + CGFloat(i) * 26 - 10)
            }
        }
    }

    private static func fieldCount(_ tasks: [TaskSummary], _ name: String) -> Int {
        tasks.filter { ($0.field ?? noField) == name }.count
    }

    /// 업무 점(10pt)들의 위치를 모아 첫 점부터 마지막 점까지 점선(1.5pt, 3/4)을 긋는다
    private func timelineSpine(_ dots: [Anchor<CGRect>]) -> some View {
        GeometryReader { geo in
            if let first = dots.first, let last = dots.last {
                Path { path in
                    path.move(to: CGPoint(x: geo[first].midX, y: geo[first].midY))
                    path.addLine(to: CGPoint(x: geo[last].midX, y: geo[last].midY))
                }
                .stroke(Color(hex: 0xCFC8C1), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            }
        }
    }

    /// 폴더 줄: 펼침 화살표, 분야 이름, 업무 수. 누르면 접고 펼친다
    private func folderRow(_ folder: TaskFolder) -> some View {
        let open = !collapsed.contains(folder.name)
        return Button {
            if open { collapsed.insert(folder.name) } else { collapsed.remove(folder.name) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.gray)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                Text(L10n.tr(key: folder.name)).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(folder.tasks.count)").font(.custom("Jost-Light", size: 13)).foregroundStyle(Brand.gray)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("\(L10n.tr(key: folder.name)) 분야, 업무 \(folder.tasks.count)개, \(open ? tr("펼침") : tr("접힘"))"))
        .contextMenu {
            if folder.name != Self.noField {                                        // '분야 없음' 은 분야가 아니라 고를 수 없다
                Button(tr("이 분야로 묻기")) { state.askAbout(theme: folder.name) }
            }
        }
        .padding(.top, 6)
    }

    /// 업무 줄(타임라인): 분야 색 점, 제목 한 줄, 아래에 분야 › 종류와 작업 시간. 고른 줄은 점에 연한 고리, 제목은 굵게
    private func taskRow(_ task: TaskSummary, color: Color) -> some View {
        let on = task.id == selectedTask
        let field = task.field ?? Self.noField
        let type = task.taskType.flatMap { $0.isEmpty || $0 == field ? nil : $0 }              // 종류가 없으면 분야만
        let meta = type.map { t in
            Text("\(Text(L10n.tr(key: field)).font(Brand.font(.caption, .medium)).foregroundStyle(Color(hex: 0x6E6862)))\(Text(" › ").font(Brand.font(.caption)).foregroundStyle(Color(hex: 0xB8AFA8)))\(Text(L10n.tr(key: t)).font(Brand.font(.caption)).foregroundStyle(Color(hex: 0x8C837C)))")
        } ?? Text(L10n.tr(key: field)).font(Brand.font(.caption, .medium)).foregroundStyle(Color(hex: 0x6E6862))
        return Button {
            if on {   // 고른 업무를 다시 누르면: 상자 지우고, 그래프 확대 풀고, 업무 상세도 닫는다
                selectedTask = nil; state.selectedTaskId = nil; state.taskDetailOpen = false
                return
            }
            selectedTask = task.id
            onSelect(task.id)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    if on { Circle().fill(color.opacity(0.25)).frame(width: 20, height: 20) }      // 고리: 점 둘레 5pt (제자리에서 나타남)
                    Circle().fill(color).frame(width: 10, height: 10)
                        .anchorPreference(key: TimelineDotKey.self, value: .bounds) { [$0] }
                }
                .frame(width: 14, height: 10).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(Brand.font(.rowTitle, on ? .semibold : .medium)).foregroundStyle(Color(hex: 0x2A201B)).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        meta.lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.rowDuration(task.activeSeconds)).font(Brand.font(.caption)).foregroundStyle(Color(hex: 0x8C837C)).fixedSize()
                    }
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 12)                             // 점 칸이 왼쪽에서 27 에 오게 (바깥 12 + 안쪽 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in Color.clear.preference(key: RowFrameKey.self, value: [task.id: g.frame(in: .named("taskList"))]) })
            .hoverHighlight(cornerRadius: 8, active: !on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contextMenu {
            Button(tr("이 업무로 묻기")) { state.askAbout(task: task) }
        }
    }

    /// 업무 줄의 시간: 1분이 안 되면 '1분 미만'
    static func rowDuration(_ seconds: Double) -> String { seconds < 60 ? tr("1분 미만") : duration(seconds) }

    /// 고른 줄 상자를 옮김: 가는 쪽 모서리가 먼저 빠르게 늘어나고, 떠나는 쪽 모서리가 조금 늦게 따라와 모임(물방울)
    private func moveBox(to id: Int64?) {
        guard let id, let f = rowFrames[id] else { boxTop = 0; boxBottom = 0; return }
        boxX = f
        guard boxBottom > boxTop else { boxTop = f.minY; boxBottom = f.maxY; return }        // 처음 고르면 그 자리에 바로
        let lead = Animation.spring(response: 0.24, dampingFraction: 0.8), trail = Animation.spring(response: 0.55, dampingFraction: 0.68).delay(0.06)
        if f.minY > boxTop {   // 아래로: 아래 모서리가 먼저, 위 모서리가 늦게
            withAnimation(lead) { boxBottom = f.maxY }; withAnimation(trail) { boxTop = f.minY }
        } else {
            withAnimation(lead) { boxTop = f.minY }; withAnimation(trail) { boxBottom = f.maxY }
        }
    }

    /// 줄 위치가 바뀌면(분야 거르기, 목록 갱신) 상자를 애니메이션 없이 고른 줄에 맞춤
    private func snapBox() {
        guard let id = selectedTask, let f = rowFrames[id] else { boxTop = 0; boxBottom = 0; return }
        boxX = f
        if boxTop != f.minY || boxBottom != f.maxY { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { boxTop = f.minY; boxBottom = f.maxY } }
    }

    // MARK: 오른쪽 상세

    /// TK-W5: 업무가 하나도 없을 때
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(tr("아직 업무가 없어요")).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink)
            Text(tr("활동이 쌓여 정리되면 업무가 여기에 모여요. 지금 바로 정리할 수도 있어요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray)
            Button(tr("지금 정리")) { Task { await state.runBatch(force: true) } }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .disabled(state.batchRunning).opacity(state.batchRunning ? 0.4 : 1)
                .padding(.top, 16)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.3.stack.3d").font(.system(size: 30, weight: .light)).foregroundStyle(Brand.sub)
            Text(tr("업무를 골라 주세요")).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink).padding(.top, 8)
            Text(tr("세션마다 그때 열었던 파일, 페이지, 앱을 다시 열 수 있어요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray)
        }
    }

    private func detail(_ task: TaskSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 이름과 단추가 한 줄에 다 들어가면 나란히, 드로어가 좁아 안 들어가면 단추를 이름 아래 줄로
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    heading(task, lines: 1)
                    Spacer(minLength: 16)
                    headerButtons(task)
                }
                VStack(alignment: .leading, spacing: 16) {
                    heading(task, lines: 2)
                    HStack(spacing: 8) { headerButtons(task) }
                }
            }
            .padding(.horizontal, 33).padding(.vertical, 30)
            .frame(maxWidth: .infinity, minHeight: 155, alignment: .leading)

            if !state.offTaskToday.isEmpty {
                // 업무 외(집중 이탈): 업무, 세션, 자료 없이 시간만
                let total = state.offTaskToday.reduce(0) { $0 + $1.seconds }
                let top = state.offTaskToday.prefix(3).map { "\($0.app) \(Self.duration($0.seconds))" }.joined(separator: ", ")
                Text(tr("업무 외 오늘 \(Self.duration(total)), \(top)"))
                    .font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineLimit(1)
                    .padding(.horizontal, 33).frame(height: 44, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    stats(task)
                    HStack(alignment: .firstTextBaseline, spacing: 22) {
                        tabButton(tr("작업 세션"), count: sessions.count, on: tab == .sessions) { tab = .sessions }
                        tabButton(tr("요약"), count: digests.count, on: tab == .digests) { tab = .digests }
                        tabButton(tr("자료"), count: Self.kinds.reduce(0) { $0 + materials[keyPath: $1.items].count }, on: tab == .materials) { tab = .materials }
                        Spacer()
                        Text(tab == .digests ? tr("주간·월간, 최근 기간 순") : tab == .materials ? tr("종류별, 처음 쓴 순") : tr("최근 활동 순")).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                    }
                    .padding(.vertical, 23)
                    if tab == .digests {
                        digestList
                    } else if tab == .materials {
                        materialsList
                    } else if sessions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "square.3.stack.3d").font(.system(size: 26, weight: .light)).foregroundStyle(Brand.gray)
                            Text(tr("아직 기록된 세션이 없어요")).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink).padding(.top, 6)
                            Text(tr("이 업무의 활동이 기록되면 시간과 사용한 자료를 함께 보여 드려요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            sessionRow(session, first: index == 0)
                        }
                    }
                    eraseButton(task).padding(.top, 40)
                }
                .padding(.horizontal, 33).padding(.bottom, 24)
            }
        }
    }

    /// 상세 맨 아래 '이 업무 지우기': 누르면 지울 것을 세어 확인 창에 보여 준다 (확인 창은 MainWindow 의 EraseDialog 하나)
    private func eraseButton(_ task: TaskSummary) -> some View {
        Button { state.askErase(NodeRef(label: NodeLabel.task, key: task.key)) } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash").font(.system(size: 11))
                Text(tr("이 업무 지우기")).font(Brand.font(.body))
            }
            .foregroundStyle(Color(hex: 0xC0573F))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.erasing)
        .help(tr("이 업무와 그 기록(원시 기록·화면 카드·요약)을 지워요. 되돌릴 수 없어요"))
    }

    private func heading(_ task: TaskSummary, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let type = task.taskType { BrandBadge(L10n.tr(key: type)) }
            }
            Text(task.title).font(Brand.font(.screenTitle)).tracking(-1.26).foregroundStyle(Brand.ink).lineLimit(lines).padding(.top, 14)
        }
    }

    @ViewBuilder
    private func headerButtons(_ task: TaskSummary) -> some View {
        let pinned = state.isTaskPinned(task.key)
        Button { state.askAbout(task: task) } label: {
            Image(systemName: "bubble.left").font(.system(size: 12))
        }
        .buttonStyle(BrandButtonStyle())
        .help(tr("이 업무로 묻기: 채팅에서 이 업무 기록만 보고 답해요"))
        .accessibilityLabel(tr("이 업무로 묻기"))
        Button { state.toggleTaskPin(task.key) } label: {
            HStack(spacing: 6) {
                Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 11))
                Text(pinned ? tr("원문 보존 중") : tr("원문 보존"))
            }
        }
        .buttonStyle(BrandButtonStyle())
        .help(tr("이 업무의 화면 텍스트와 활동 기록을 보관 기간이 지나도 지우지 않아요"))
        Button { state.prepareResume(taskId: task.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 12))
                Text(tr("다시 열기"))
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(BrandButtonStyle(kind: .primary))
    }

    private func stats(_ task: TaskSummary) -> some View {
        let minutes = Int(task.activeSeconds / 60)
        return HStack(alignment: .top, spacing: 0) {
            statCell(tr("작업 시간"), note: tr("누적 작업 시간"), leading: false) {
                bigNumber(minutes >= 60 ? [("\(minutes / 60)", tr("시간")), ("\(minutes % 60)", tr("분"))] : [("\(minutes)", tr("분"))])
            }
            statCell(tr("세션"), note: tr("이어진 작업 세션"), leading: true) {
                bigNumber([(String(format: "%02d", task.sessionCount), tr("개"))])
            }
            statCell(tr("마지막 활동"), note: tr("내 업무 기록"), leading: true) {
                Text(task.sessionCount == 0 ? tr("활동 없음") : Self.lastActive(task.lastActive))
                    .font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink).frame(height: 60)
            }
        }
        .padding(.top, 28).padding(.bottom, 28)
    }

    /// 큰 숫자와 작은 단위를 한 글줄로 (예: 2 시간  40 분). 칸이 좁으면(드로어가 줄면) 잘리지 않고 통째로 작아진다
    private func bigNumber(_ parts: [(value: String, unit: String)]) -> some View {
        parts.enumerated().reduce(Text(verbatim: "")) { line, part in
            let gap = Text(verbatim: part.offset == 0 ? "" : "   ").font(Brand.font(.caption))
            let value = Text(verbatim: part.element.value).font(.custom("Jost-ExtraLight", size: 48)).foregroundStyle(Brand.ink)
            let unit = Text(verbatim: " " + part.element.unit).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
            return Text("\(line)\(gap)\(value)\(unit)")
        }
        .lineLimit(1).minimumScaleFactor(0.5)
    }

    private func statCell<Content: View>(_ eyebrow: String, note: String, leading: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(eyebrow)
            content().frame(height: 60, alignment: .leading)
            Text(note).font(Brand.font(.tag)).foregroundStyle(Brand.gray).padding(.top, 0)
        }
        .padding(.leading, leading ? 29 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionRow(_ session: SessionSummary, first: Bool) -> some View {
        let start = Date(timeIntervalSince1970: session.start)
        let range = Self.clock.string(from: start) + (session.end > session.start ? " — " + Self.clock.string(from: Date(timeIntervalSince1970: session.end)) : "")
        let meta = [session.apps.joined(separator: ", "), session.resourceCount > 0 ? tr("자료 \(session.resourceCount)개") : ""].filter { !$0.isEmpty }
        return HStack(alignment: .top, spacing: 18) {
            RoundedRectangle(cornerRadius: 1).fill(first ? Brand.ink : .white)
                .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(first ? Brand.ink : Color(hex: 0xBDB5AE)))
                .frame(width: 7, height: 7).padding(.top, 7)
                .frame(width: 9)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Text(Self.dayLabel(start)).font(Brand.font(.caption, .medium)).foregroundStyle(Brand.tabText)
                    Text(range).font(Brand.jost(12)).tracking(0.18).foregroundStyle(Brand.gray)
                    Spacer()
                    Text(Self.duration(max(0, session.end - session.start))).font(Brand.font(.body)).foregroundStyle(Brand.tabText)
                }
                if session.summaries.isEmpty {
                    Text(session.title).font(Brand.font(.body)).foregroundStyle(Brand.tabText).lineLimit(2).padding(.top, 11)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(session.summaries.prefix(4).enumerated()), id: \.offset) { _, line in
                            Text(line).font(Brand.font(.body)).foregroundStyle(Brand.tabText).lineLimit(2)
                        }
                        if session.summaries.count > 4 { Text(tr("외 \(session.summaries.count - 4)개")).font(Brand.font(.tag)).foregroundStyle(Brand.gray) }
                    }
                    .padding(.top, 11)
                }
                HStack {
                    Text(meta.joined(separator: "   |   ")).font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1)
                    Spacer()
                    Button { state.prepareResume(sessionId: session.id) } label: {
                        HStack(spacing: 6) {
                            Text(tr("다시 열기")).font(Brand.font(.caption))
                            Image(systemName: "arrow.up.right").font(.system(size: 10))
                        }
                        .foregroundStyle(Brand.tabText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
            }
            .padding(.bottom, 26)
        }
    }

    private func tabButton(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Brand.font(.body)).foregroundStyle(on ? Brand.ink : Brand.gray)
                Text("\(count)").font(Brand.jost(12)).foregroundStyle(Brand.gray)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { if on { Rectangle().fill(Brand.ink).frame(height: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 자료 (그래프 업무 팝업과 같은 기준)

    /// 누르면 여는 것: 자료는 주소로, 앱은 번들 id 로
    enum Opens { case resource, app, none }
    /// 종류: 이름, 그래프와 같은 색, 목록, 누르면 여는 것
    static let kinds: [(name: String, color: Color, items: KeyPath<TaskMaterials, [TaskMaterials.Item]>, opens: Opens)] = [
        (tr("참고자료"), Color(hex: 0x00929E), \.references, .resource),
        (tr("산출물"), Color(hex: 0xB48F3C), \.outputs, .resource),
        (tr("앱"), Color(hex: 0x915A95), \.apps, .app),
        (tr("주제"), Color(hex: 0x5A9E6A), \.topics, .none),
        (tr("문제"), Color(hex: 0xAB5242), \.problems, .none),
        (tr("나중에 할 일"), Color(hex: 0x6885C3), \.later, .none),
    ]
    private static let shownPerKind = 6

    @ViewBuilder private var materialsList: some View {
        if materials.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 26, weight: .light)).foregroundStyle(Brand.gray)
                Text(tr("아직 모인 자료가 없어요")).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink).padding(.top, 6)
                Text(tr("세션에서 쓴 자료, 앱, 주제가 여기에 모여요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Self.kinds, id: \.name) { kind in
                    let items = materials[keyPath: kind.items]
                    if !items.isEmpty { kindSection(kind.name, color: kind.color, items: items, opens: kind.opens) }
                }
                if !materials.related.isEmpty { relatedSection }
            }
        }
    }

    private func kindSection(_ name: String, color: Color, items: [TaskMaterials.Item], opens: Opens) -> some View {
        let open = openKinds.contains(name)
        let shown = open ? items : Array(items.prefix(Self.shownPerKind))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(Brand.font(.body, .semibold)).foregroundStyle(Brand.ink)
                Text("\(items.count)").font(Brand.jost(12)).foregroundStyle(Brand.gray)
            }
            .padding(.bottom, 8)
            ForEach(shown) { item in itemRow(item, opens: opens) }
            if items.count > Self.shownPerKind {
                Button { if open { openKinds.remove(name) } else { openKinds.insert(name) } } label: {
                    Text(open ? tr("접기") : tr("외 \(items.count - Self.shownPerKind)개 더 보기")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                        .padding(.vertical, 6).padding(.leading, 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func itemRow(_ item: TaskMaterials.Item, opens: Opens) -> some View {
        let label = HStack(spacing: 8) {
            Text(item.name).font(Brand.font(.body)).foregroundStyle(Brand.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if opens != .none { Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Brand.gray) }
        }
        .padding(.horizontal, 14).frame(height: 30).frame(maxWidth: .infinity, alignment: .leading)
        switch opens {
        case .resource:
            Button { state.openGraphItem(uri: item.key) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain).hoverHighlight(cornerRadius: 6).help(item.key)
        case .app:
            Button { state.openApp(bundle: item.key) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain).hoverHighlight(cornerRadius: 6)
        case .none:
            label
        }
    }

    /// 같은 맥락 업무: 같은 자료나 주제를 쓴 업무. 누르면 드로어가 그 업무로 바뀐다
    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Brand.ink.opacity(0.55)).frame(width: 7, height: 7)
                Text(tr("같은 맥락 업무")).font(Brand.font(.body, .semibold)).foregroundStyle(Brand.ink)
                Text("\(materials.related.count)").font(Brand.jost(12)).foregroundStyle(Brand.gray)
            }
            .padding(.bottom, 8)
            ForEach(materials.related) { related in
                Button { selectedTask = related.taskId; state.openTaskDetail(id: related.taskId) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(related.title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                            Text(tr("함께 쓴 항목 \(related.shared.count)개, \(related.shared.prefix(2).joined(separator: ", "))"))
                                .font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight(cornerRadius: 6)
                .help(related.shared.joined(separator: ", "))
            }
        }
    }

    // MARK: 요약

    @ViewBuilder private var digestList: some View {
        if digests.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "text.alignleft").font(.system(size: 24, weight: .light)).foregroundStyle(Brand.gray)
                Text(tr("아직 요약이 없어요")).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink).padding(.top, 6)
                Text(tr("한 주가 끝나고 이틀 뒤, 그 주의 활동을 요약해 둬요. 오래된 원문은 이 요약이 대신해요."))
                    .font(Brand.font(.body)).foregroundStyle(Brand.gray).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            ForEach(digests) { digest in digestCard(digest) }
        }
    }

    private func digestCard(_ digest: Digest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(Self.periodLabel(digest)).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText)
                switch digest.status {
                case .draft: GrayBadge(tr("초안"))
                case .edited: BrandBadge(tr("수정함"))
                case .verified: EmptyView()
                }
                Spacer()
                Button(tr("고치기")) { editing = digest }.buttonStyle(.plain).font(Brand.font(.caption)).foregroundStyle(Brand.tabText)
            }
            if digest.status == .draft, digest.attempts >= DigestBuilder.maxAttempts {
                Text(digest.level == .week ? tr("AI 요약이 검증을 통과하지 못해 기록을 모아 만든 초안이에요. 그래서 이 주 원문은 지우지 않아요. '고치기'에서 확인하고 저장하면 유예 기간 뒤 정리돼요.")
                                           : tr("AI 요약이 검증을 통과하지 못해 기록을 모아 만든 초안이에요."))
                    .font(Brand.font(.caption)).foregroundStyle(Brand.gray).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(digest.body.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, line in
                    Text(Self.inline(String(line))).font(Brand.font(.body)).foregroundStyle(Brand.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF9F8F7)))
        .padding(.bottom, 12)
    }

    static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
    }

    static func periodLabel(_ digest: Digest) -> String {
        let calendar = PeriodCalendar(timeZone: TimeZone(identifier: digest.tz) ?? .current)
        func short(_ day: String) -> String {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? "\(parts[1])/\(parts[2])" : day
        }
        let first = calendar.day(digest.periodStart), last = calendar.day(digest.periodEnd - 1)
        return "\(digest.level == .week ? tr("주간") : tr("월간")) · \(short(first))~\(short(last))"
    }

    private func reload() {
        sessions = selectedTask.map { state.sessions(ofTask: $0) } ?? []
        digests = selectedTask.flatMap { id in state.taskList.first { $0.id == id } }.map { state.digests(forTask: $0.key) } ?? []
        materials = selectedTask.map { state.taskMaterials($0) } ?? TaskMaterials()
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? tr("\(minutes / 60)시간 \(minutes % 60)분") : tr("\(max(minutes, seconds > 0 ? 1 : 0))분")
    }

    static func dayLabel(_ date: Date) -> String {
        (Calendar.current.isDateInToday(date) ? tr("오늘, ") : "") + day.string(from: date)
    }

    private static func lastActive(_ stamp: Double) -> String {
        let date = Date(timeIntervalSince1970: stamp)
        return (Calendar.current.isDateInToday(date) ? tr("오늘") : day.string(from: date)) + " " + clock.string(from: date)
    }
}

/// 열 것을 확인하는 시트
struct ResumeSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var request: ResumeRequest
    /// 처음 켜져 있던 것. 체크를 바꿔도 칸이 옮겨 다니지 않게 고정한다
    private let initiallySelected: Set<String>

    init(request: ResumeRequest) {
        _request = State(initialValue: request)
        initiallySelected = Set(request.plan.items.filter(\.selected).map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("다시 열기")).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink)
                    Text(request.plan.title).font(Brand.font(.body)).foregroundStyle(Brand.gray).lineLimit(2).padding(.top, 10)
                }
                Spacer()
                Button { state.resumeRequest = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Brand.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 20)
            if request.plan.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.3.stack.3d").font(.system(size: 26, weight: .light)).foregroundStyle(Brand.sub)
                    Text(tr("다시 열 수 있는 파일이나 페이지가 남아 있지 않아요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray)
                }
                .frame(maxWidth: .infinity, minHeight: 195)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        group(tr("마지막에 하던 것"), selected: true)
                        if request.plan.items.contains(where: { !initiallySelected.contains($0.id) }) {
                            group(tr("그때 함께 열었던 것"), selected: false)
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 6)
                }
                .frame(minHeight: 220, maxHeight: 375)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(tr("취소")) { state.resumeRequest = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                Button(tr("열기 (\(request.plan.selectedItems.count)개)")) { state.runResume(request.plan) }
                    .keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle(kind: .primary))
                    .disabled(request.plan.selectedItems.isEmpty)
                    .opacity(request.plan.selectedItems.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 24).frame(height: 63)
            .background(Brand.paper)
        }
        .frame(width: 600)
        .background(.white)
    }

    private func group(_ title: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.gray).padding(.top, 14).padding(.bottom, 8)
            ForEach($request.plan.items) { $item in
                if initiallySelected.contains(item.id) == selected { row($item) }
            }
        }
    }

    private func row(_ item: Binding<ResumePlan.Item>) -> some View {
        let on = item.wrappedValue.selected
        return Button { item.selected.wrappedValue.toggle() } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 3).fill(on ? Brand.ink : .white)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? Brand.ink : Brand.line))
                    .overlay { if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) } }
                    .frame(width: 14, height: 14)
                Image(systemName: icon(item.wrappedValue.kind)).font(.system(size: 12)).foregroundStyle(Brand.gray).frame(width: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.wrappedValue.title).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink).lineLimit(1)
                    Text(detail(item.wrappedValue)).font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.vertical, 10)                                                       // 줄 사이 선 대신 간격
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ kind: ResumePlan.Kind) -> String {
        switch kind {
        case .folder: return "folder"
        case .file: return "doc"
        case .url: return "globe"
        case .app: return "app"
        }
    }

    private func detail(_ item: ResumePlan.Item) -> String {
        let home = NSHomeDirectory()
        let target = item.target.hasPrefix(home) ? "~" + item.target.dropFirst(home.count) : item.target
        let app = item.appBundle.flatMap { bundle in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        }
        if item.kind == .app { return tr("앱 열기") }
        return app.map { "\($0), \(target)" } ?? target
    }
}

/// 요약 고치기. 저장하면 '수정함'이 되고 자동으로 다시 만들지 않는다
struct DigestEditSheet: View {
    let digest: Digest
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var text: String

    init(digest: Digest, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.digest = digest; self.save = save; self.cancel = cancel
        _text = State(initialValue: digest.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("요약 고치기")).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink)
                Text(digest.title).font(Brand.font(.body)).foregroundStyle(Brand.gray).lineLimit(1).padding(.top, 10)
            }
            .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 18)
            TextEditor(text: $text)
                .font(Brand.font(.body)).scrollContentBackground(.hidden)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF9F8F7)))
                .frame(minHeight: 320)
                .padding(.horizontal, 32).padding(.top, 18)
            Text(tr("저장하면 '수정함'으로 바뀌고 자동으로 다시 만들지 않아요. 채팅도 고친 내용을 요약으로 읽어요."))
                .font(Brand.font(.caption)).foregroundStyle(Brand.gray).padding(.horizontal, 32).padding(.vertical, 12)
            HStack(spacing: 8) {
                Spacer()
                Button(tr("취소"), action: cancel).keyboardShortcut(.cancelAction).buttonStyle(BrandButtonStyle(kind: .secondary))
                Button(tr("저장")) { save(text) }.keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle(kind: .primary))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24).frame(height: 63)
            .background(Brand.paper)
        }
        .frame(width: 640)
        .background(.white)
    }
}

/// TK-W4 업무 불러오는 중. AppState에 상태가 생기면 쓴다
private struct TasksLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(tr("업무를 불러오고 있어요")).font(Brand.font(.body)).foregroundStyle(Brand.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// TK-W6 업무를 불러오지 못할 때. AppState에 상태가 생기면 쓴다
private struct TasksErrorView: View {
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Text(tr("업무를 불러오지 못했어요")).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink)
            Text(tr("기록을 읽는 중에 문제가 생겼어요. 잠시 뒤 다시 시도해 주세요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray)
            Button(tr("다시 시도"), action: retry).buttonStyle(BrandButtonStyle(kind: .secondary)).padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 업무 줄 위치(목록 좌표)
private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// 업무 점들의 위치를 모은다 (점선을 첫 점에서 마지막 점까지 긋는 데 쓴다)
private struct TimelineDotKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}
