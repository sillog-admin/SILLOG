import SwiftUI
import SillogCore

/// 업무: 왼쪽 업무 트리(분야 폴더 안에 업무), 오른쪽 업무 상세(세션 목록과 다시 열기). Figma 참고 TK-01, TK-02, TK-W1.
/// 창에서는 업무 패널(TasksPanel)이 목록만 보이다가 업무를 고르면 상세까지 펼친다
struct TasksView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedTask: Int64?
    @State private var collapsed: Set<String> = []          // 접은 분야 폴더
    @State private var fieldFilter: Set<String> = []        // 분야 막대에서 고른 분야들 (다시 누르면 빠짐, 비면 전체)
    @State private var typeFilter: Set<String> = []         // type pills chosen under the open fields (typeKey); a field with none shows all its tasks
    @State private var rowFrames: [Int64: CGRect] = [:]     // 업무 줄 위치(목록 좌표). 고른 줄 상자를 옮기는 데 씀
    @State private var boxTop: CGFloat = 0                  // 고른 줄 상자 위 모서리. 위아래를 따로 움직여 물방울처럼 늘었다 모임
    @State private var boxBottom: CGFloat = 0
    @State private var boxX = CGRect.zero                   // 가로 위치와 폭(줄마다 같음)
    @State private var sessions: [SessionSummary] = []
    @AppStorage("taskDetailRange") private var rangeRaw = RangeTime.Range.week.rawValue
    @State private var hoveredSession: Int64?               // 다시 열기 단추를 보일 세션
    @State private var hoveredBar: Int?                     // 날짜와 시간을 보일 막대
    @State private var digests: [Digest] = []
    @State private var tab: DetailTab
    @State private var materials = TaskMaterials()
    @State private var openKinds: Set<String> = []          // 자료 탭에서 '더 보기'로 펼친 종류
    @State private var editing: Digest?
    /// 목록에서 업무를 눌렀을 때 (업무 패널이 상세를 펼친다)
    private let onSelect: (Int64) -> Void
    /// 상세를 그릴지 (업무 패널은 목록만)
    private let showsDetail: Bool
    /// 목록을 그릴지 (상세 카드는 상세만)
    private let showsList: Bool

    /// 상세의 탭: 작업 세션, 요약(주간·월간), 자료(그래프 업무 팝업과 같은 종류별 자료와 같은 맥락 업무)
    enum DetailTab { case sessions, digests, materials }

    /// 스냅샷용: 고른 업무와 탭으로 시작
    init(selectedTask: Int64? = nil, tab: DetailTab = .sessions, showsList: Bool = true, showsDetail: Bool = true, onSelect: @escaping (Int64) -> Void = { _ in }) {
        _selectedTask = State(initialValue: selectedTask)
        _tab = State(initialValue: tab)
        self.showsList = showsList
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
            if showsList { sidebar.frame(width: 277) }
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
        let shown = state.taskList.filter { Self.passes($0, fields: filter, types: typeFilter) }   // 받은 순서(최근 활동 순) 그대로
        let colors = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.color) })
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(tr("업무")).font(Brand.font(.screenTitle)).tracking(-0.8).foregroundStyle(Brand.ink)
                    Text("\(state.taskList.count)").font(Brand.font(.sectionTitle)).foregroundStyle(Brand.gray)
                }
                if !state.offTaskToday.isEmpty {
                    // 업무 외(집중 이탈): 하루 전체 수치라 업무 상세가 아니라 목록 위에. 앱별 시간은 커서를 대면
                    let total = state.offTaskToday.reduce(0) { $0 + $1.seconds }
                    Text(tr("업무 외 오늘 \(Self.duration(total))")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                        .help(state.offTaskToday.prefix(5).map { "\($0.app) \(Self.duration($0.seconds))" }.joined(separator: "\n"))
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
            if fieldFilter.contains(name) { fieldFilter.remove(name); typeFilter = typeFilter.filter { !$0.hasPrefix(Self.typeKey(name, "")) } } else { fieldFilter.insert(name) }
        }
    }

    /// 분야 비율 막대: 분야마다 업무 수에 비례한 둥근 조각. 누르면 넣고 빼며(여러 개), 고른 분야는 아래로 늘어나 종류 나무가 펼쳐진다
    private func fieldBar(_ fields: [FieldStat], filter: Set<String>) -> some View {
        let width: CGFloat = 277 - 27 * 2                                                 // shortcut: the sidebar is a fixed 277pt with 27pt padding
        let sel = fields.filter { filter.contains($0.name) }
        let rows = sel.map { Self.typeRows(state.taskList, field: $0.name) }
        let total = CGFloat(fields.reduce(0) { $0 + $1.count })
        let room = width - 3 * CGFloat(fields.count - 1)
        let widths = fields.map { max(8, room * CGFloat($0.count) / total) }
        let starts: [CGFloat] = widths.indices.map { i in widths[..<i].reduce(CGFloat(0), +) + 3 * CGFloat(i) }
        let at = sel.map { field in fields.firstIndex { $0.id == field.id } ?? 0 }
        let colW = width / CGFloat(max(sel.count, 1))
        let plan = Self.treeLayout(circles: at.indices.map { k in max(starts[at[k]] + 12, CGFloat(k) * colW + 12) },
                                   needs: rows.map { $0.map { Self.pillWidth(L10n.tr(key: $0.label), $0.count) }.max() ?? 0 },
                                   rows: rows.map(\.count), width: width)
        let pillRows = zip(plan.spots, rows).map { $0.top + $1.count }.max() ?? 1
        return ZStack(alignment: .topLeading) {
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
                fieldTree(field, rows: rows[k], a: starts[at[k]], b: starts[at[k]] + widths[at[k]], cx: plan.circles[k], spot: plan.spots[k])
                    .offset(y: 8)
                    .transition(.scale(scale: 0.01, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: width, height: 8 + (sel.isEmpty ? 22 : 46 + CGFloat(max(pillRows, 1) - 1) * 26 + 14), alignment: .topLeading)
    }

    /// 그 분야 업무의 종류별 개수: 많은 순, 최대 4개, 넘치면 마지막에 "외 N". 종류가 비었거나 분야와 같으면 세지 않는다.
    /// types: the task types a pill stands for ("외 N" stands for the rest)
    static func typeRows(_ tasks: [TaskSummary], field: String) -> [(label: String, count: Int, types: [String])] {
        var counts: [String: Int] = [:]
        for t in tasks where (t.field ?? noField) == field {
            if let type = t.taskType, !type.isEmpty, type != field { counts[type, default: 0] += 1 }
        }
        let sorted = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var rows = sorted.prefix(4).map { (label: $0.key, count: $0.value, types: [$0.key]) }
        if sorted.count > 4 { rows.append((tr("외 \(sorted.count - 4)"), sorted.dropFirst(4).reduce(0) { $0 + $1.value }, sorted.dropFirst(4).map(\.key))) }
        return rows
    }

    static func typeKey(_ field: String, _ type: String) -> String { field + "\u{1F}" + type }

    /// Whether a task stays in the list: in a chosen field (or none chosen), and of a chosen type when its field has type picks
    static func passes(_ task: TaskSummary, fields: Set<String>, types: Set<String>) -> Bool {
        let field = task.field ?? noField
        if !fields.isEmpty, !fields.contains(field) { return false }
        let picks = types.filter { $0.hasPrefix(typeKey(field, "")) }
        return picks.isEmpty || picks.contains(typeKey(field, task.taskType ?? ""))
    }

    private func toggleTypes(_ field: String, _ types: [String]) {
        let keys = Set(types.map { Self.typeKey(field, $0) })
        if keys.isSubset(of: typeFilter) { typeFilter.subtract(keys) } else { typeFilter.formUnion(keys) }
    }

    /// Width a type pill needs: padding, the medium type name, a gap and the count
    static func pillWidth(_ label: String, _ count: Int) -> CGFloat {
        func width(_ text: String, _ weight: Brand.Weight) -> CGFloat {
            let font = NSFont(name: "SUIT-\(weight.rawValue)", size: 11 * Brand.scale) ?? .systemFont(ofSize: 11 * Brand.scale)
            return ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        return 18 + width(label, .medium) + 5 + width("\(count)", .regular) + 2
    }

    /// Where one field tree's type pills go: which side of its circle, how wide, and the first pill row (0 = right under the circles)
    struct TreeSpot: Equatable { var left: Bool; var room: CGFloat; var top: Int }

    /// Lays out the chosen field trees so every pill gets the width it needs and nothing crosses: a tree's pills open beside its
    /// circle up to the next line still running down, trees that do not fit drop below the earlier pills, and when no tree fits
    /// at first the circles on one side spread out to make room.
    /// Args: circles: circle x per tree (left to right), needs: widest pill per tree, rows: pills per tree, width: bar width
    static func treeLayout(circles: [CGFloat], needs: [CGFloat], rows: [Int], width: CGFloat) -> (circles: [CGFloat], spots: [TreeSpot]) {
        var cx = circles, spots = [TreeSpot?](repeating: nil, count: circles.count), active = Array(circles.indices)
        func room(_ k: Int, _ left: Bool, _ cx: [CGFloat]) -> CGFloat {
            let p = active.firstIndex(of: k)!
            let lo = p > 0 ? cx[active[p - 1]] + 15 : 0, hi = p < active.count - 1 ? cx[active[p + 1]] - 15 : width - 4
            return max(0, left ? cx[k] - 14 - lo : hi - cx[k] - 14)
        }
        func spread(_ k: Int, _ left: Bool) -> [CGFloat] {                                // push the circles beside k away, kept 26pt apart and on the bar
            var c = cx
            if left {
                for j in stride(from: k - 1, through: 0, by: -1) { c[j] = min(c[j], j == k - 1 ? c[k] - 29 - needs[k] : c[j + 1] - 26) }
                if c[0] < 11 { c[0] = 11; for j in 1..<k { c[j] = max(c[j], c[j - 1] + 26) } }
            } else {
                for j in (k + 1)..<c.count { c[j] = max(c[j], j == k + 1 ? c[k] + 29 + needs[k] : c[j - 1] + 26) }
                if let last = c.indices.last, c[last] > width - 11 { c[last] = width - 11; for j in stride(from: last - 1, to: k, by: -1) { c[j] = min(c[j], c[j + 1] - 26) } }
            }
            return c
        }
        while !active.isEmpty {
            let options = active.flatMap { k in [(k: k, left: true), (k: k, left: false)] }
            var pick = options.filter { room($0.k, $0.left, cx) >= needs[$0.k] }.max { room($0.k, $0.left, cx) < room($1.k, $1.left, cx) }
            if pick == nil, spots.allSatisfy({ $0 == nil }) {                               // nothing fits yet: spread the circles for the best tree
                let best = options.max { room($0.k, $0.left, spread($0.k, $0.left)) - needs[$0.k] < room($1.k, $1.left, spread($1.k, $1.left)) - needs[$1.k] }!
                cx = spread(best.k, best.left); pick = best
            }
            let p = pick ?? options.max { room($0.k, $0.left, cx) - needs[$0.k] < room($1.k, $1.left, cx) - needs[$1.k] }!
            let w = min(room(p.k, p.left, cx), needs[p.k])
            let region = p.left ? (cx[p.k] - 14 - w)...(cx[p.k] - 14) : (cx[p.k] + 14)...(cx[p.k] + 14 + w)
            var top = 0                                                                    // below every earlier tree whose pills or line are in the way
            for u in cx.indices { if let s = spots[u] {
                let r = s.left ? (cx[u] - 14 - s.room)...(cx[u] - 14) : (cx[u] + 14)...(cx[u] + 14 + s.room)
                if region.overlaps(min(r.lowerBound, cx[u])...max(r.upperBound, cx[u])) { top = max(top, s.top + rows[u]) }
            } }
            spots[p.k] = TreeSpot(left: p.left, room: w, top: top)
            active.removeAll { $0 == p.k }
        }
        return (cx, spots.map { $0! })
    }

    /// 막대 조각(a..b) 아래로 늘어난 목과 동그라미, 종류 가지와 알약. 좌표는 막대 아래 끝이 y=0
    private func fieldTree(_ field: FieldStat, rows: [(label: String, count: Int, types: [String])], a: CGFloat, b: CGFloat, cx: CGFloat, spot: TreeSpot) -> some View {
        let side: CGFloat = spot.left ? -1 : 1                                            // branches and pills go this way from the circle
        let count = TasksView.fieldCount(state.taskList, field.name)
        let firstY = 46 + CGFloat(spot.top) * 26                                          // a tree that did not fit beside the others hangs lower
        let lastY = firstY + CGFloat(max(rows.count, 1) - 1) * 26
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
                    p.addQuadCurve(to: CGPoint(x: cx + 6 * side, y: lastY), control: CGPoint(x: cx, y: lastY))
                    p.addLine(to: CGPoint(x: cx + 12 * side, y: lastY))
                    for i in 0..<(rows.count - 1) {
                        let y = firstY + CGFloat(i) * 26
                        p.move(to: CGPoint(x: cx, y: y)); p.addLine(to: CGPoint(x: cx + 12 * side, y: y))
                    }
                }
                .stroke(field.color.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                let on = Set(row.types.map { Self.typeKey(field.name, $0) }).isSubset(of: typeFilter)
                Button { toggleTypes(field.name, row.types) } label: {                    // narrows the list to this type
                    HStack(spacing: 5) {
                        Text(L10n.tr(key: row.label)).font(Brand.font(.caption, on ? .semibold : .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                        Text("\(row.count)").font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineLimit(1)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 9)
                    .background(Capsule().fill(field.color.opacity(on ? 0.34 : 0.13)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: spot.room, alignment: spot.left ? .trailing : .leading)
                .frame(height: 20)
                .offset(x: spot.left ? cx - 14 - spot.room : cx + 14, y: firstY + CGFloat(i) * 26 - 10)
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

    /// The chosen row toggles off only while its own card shows; otherwise pressing it (re)opens that task
    static func pressCloses(chosen: Bool, cardOpen: Bool, showingNode: Bool) -> Bool { chosen && cardOpen && !showingNode }

    /// Task row: field dot, title, field › type, then the total time with the 14-day bars at the right edge. The chosen row gets a ring and a bold title
    private func taskRow(_ task: TaskSummary, color: Color) -> some View {
        let on = task.id == selectedTask
        let field = task.field ?? Self.noField
        let type = task.taskType.flatMap { $0.isEmpty || $0 == field ? nil : $0 }              // 종류가 없으면 분야만
        let meta = type.map { t in
            Text("\(Text(L10n.tr(key: field)).font(Brand.font(.caption, .medium)).foregroundStyle(Color(hex: 0x6E6862)))\(Text(" › ").font(Brand.font(.caption)).foregroundStyle(Color(hex: 0xB8AFA8)))\(Text(L10n.tr(key: t)).font(Brand.font(.caption)).foregroundStyle(Color(hex: 0x8C837C)))")
        } ?? Text(L10n.tr(key: field)).font(Brand.font(.caption, .medium)).foregroundStyle(Color(hex: 0x6E6862))
        return Button {
            if Self.pressCloses(chosen: on, cardOpen: state.taskDetailOpen, showingNode: state.openNode != nil) {   // clears the box and the graph zoom too
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
                    meta.lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {               // bars last so they line up whatever the time text width
                        Text(Self.rowDuration(task.activeSeconds)).font(Brand.font(.caption)).foregroundStyle(Color(hex: 0x8C837C)).fixedSize()
                        Spacer(minLength: 4)
                        if !task.recent.isEmpty {
                            ActivityBars(values: task.recent, color: color, height: 11)
                                .frame(width: 48).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                                .help(tr("최근 14일 하루 작업 시간"))
                                .accessibilityLabel(tr("최근 14일 하루 작업 시간"))
                        }
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
        let range = RangeTime.Range(rawValue: rangeRaw) ?? .week
        let now = Date().timeIntervalSince1970
        let from = RangeTime.start(of: range, now: now) ?? -.infinity
        let shown = sessions.filter { $0.start >= from }                   // 세션 목록도 고른 기간만
        return VStack(alignment: .leading, spacing: 0) {
            // 이름과 단추가 한 줄에 다 들어가면 나란히, 카드가 좁아 안 들어가면 단추를 이름 아래 줄로
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
            .padding(.horizontal, 33).padding(.top, 28).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summary(range, now: now)
                    HStack(alignment: .firstTextBaseline, spacing: 22) {
                        tabButton(tr("작업 세션"), count: shown.count, on: tab == .sessions) { tab = .sessions }
                        tabButton(tr("요약"), count: digests.count, on: tab == .digests) { tab = .digests }
                        tabButton(tr("자료"), count: Self.kinds.reduce(0) { $0 + materials[keyPath: $1.items].count }, on: tab == .materials) { tab = .materials }
                    }
                    .padding(.top, 26).padding(.bottom, 18)
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
                    } else if shown.isEmpty {
                        Text(tr("이 기간에는 세션이 없어요. 기간을 넓혀 보세요."))
                            .font(Brand.font(.body)).foregroundStyle(Brand.gray).frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        ForEach(RangeTime.byDay(shown, start: \.start), id: \.day) { group in
                            dayGroup(group.day, group.items)
                        }
                    }
                }
                .padding(.horizontal, 33).padding(.bottom, 24)
            }
        }
    }

    private func heading(_ task: TaskSummary, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let type = task.taskType { BrandBadge(L10n.tr(key: type)) }
                if state.isTaskPinned(task.key) { GrayBadge(tr("원문 보존 중")) }
            }
            Text(task.title).font(Brand.font(.screenTitle)).tracking(-1.26).foregroundStyle(Brand.ink).lineLimit(lines).padding(.top, 14)
        }
    }

    /// 묻기, 다시 열기, 그리고 자주 안 쓰는 원문 보존·지우기는 ··· 메뉴에
    @ViewBuilder
    private func headerButtons(_ task: TaskSummary) -> some View {
        let pinned = state.isTaskPinned(task.key)
        Button { state.askAbout(task: task) } label: {
            Image(systemName: "bubble.left").font(.system(size: 12))
        }
        .buttonStyle(BrandButtonStyle())
        .help(tr("이 업무로 묻기: 채팅에서 이 업무 기록만 보고 답해요"))
        .accessibilityLabel(tr("이 업무로 묻기"))
        Button { state.prepareResume(taskId: task.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 12))
                Text(tr("다시 열기"))
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(BrandButtonStyle(kind: .primary))
        Menu {
            // 원문 보존: 이 업무의 화면 텍스트와 활동 기록을 보관 기간이 지나도 지우지 않는다
            Toggle(tr("원문 보존"), isOn: Binding(get: { pinned }, set: { _ in state.toggleTaskPin(task.key) }))
            Divider()
            // 지울 것을 세어 확인 창에 보여 준다 (확인 창은 MainWindow 의 EraseDialog 하나)
            Button(tr("이 업무 지우기"), role: .destructive) { state.askErase(NodeRef(label: NodeLabel.task, key: task.key)) }
                .disabled(state.erasing)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13))
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(BrandButtonStyle()).fixedSize()
        .help(tr("원문 보존, 이 업무 지우기"))
        .accessibilityLabel(tr("더 보기"))
    }

    /// 기간 고르기, 합계 한 줄, 날짜별 막대
    private func summary(_ range: RangeTime.Range, now: Double) -> some View {
        let times = sessions.map { (start: $0.start, seconds: $0.activeSeconds) }
        let time = RangeTime.of(times, range: range, now: now)
        let bars = RangeTime.bars(times, range: range, now: now)
        let weekly = bars.count > 1 && bars[1].start.timeIntervalSince(bars[0].start) > 2 * 86_400
        let total = Text(Self.duration(time.seconds)).font(Brand.suit(22, .semibold)).tracking(-0.6).foregroundStyle(Brand.ink)
        let note = Text(Self.rangeNote(time, range)).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
        let tips = Dictionary(uniqueKeysWithValues: RangeTime.Range.allCases.map { range in
            (range.rawValue, Self.rangeSpan(range, first: sessions.map(\.start).min(), now: now))
        })
        let hovered = hoveredBar.flatMap { bars.indices.contains($0) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 14) {
            PillPicker(selection: $rangeRaw, options: RangeTime.Range.allCases.map { ($0.rawValue, Self.rangeName($0)) }, tips: tips)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { total; note.lineLimit(1) }
                VStack(alignment: .leading, spacing: 4) { total; note }
            }
            if let first = bars.first, !sessions.isEmpty {                     // 세션이 아예 없으면 빈 막대 대신 아래 안내만
                VStack(spacing: 6) {
                    ActivityBars(values: bars.map(\.seconds), color: Color(hex: 0xB3A69C), height: 40, highlight: hovered,
                                 onHover: { hoveredBar = $0 })
                    // 아래 줄: 평소엔 첫날과 오늘, 막대에 커서를 대면 그 막대 밑에 날짜와 시간
                    GeometryReader { g in
                        if let index = hovered {
                            let x = (CGFloat(index) + 0.5) * g.size.width / CGFloat(bars.count)
                            Text(Self.barLabel(bars[index], weekly: weekly)).font(Brand.font(.tag, .semibold)).foregroundStyle(Brand.ink)
                                .fixedSize().position(x: min(max(x, 62), g.size.width - 62), y: g.size.height / 2)
                        } else {
                            HStack {
                                Text(Self.day.string(from: first.start))
                                Spacer()
                                Text(tr("오늘"))
                            }
                            .font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                        }
                    }
                    .frame(height: 13)
                }
                .padding(.top, 4)
            }
        }
        .padding(.top, 18)
    }

    /// 막대에 커서를 대면: 날짜(한 주면 그 주 첫날부터)와 그날 시간
    static func barLabel(_ bar: RangeTime.Bar, weekly: Bool) -> String {
        let day = Self.day.string(from: bar.start)
        return weekly ? tr("\(day)부터 한 주 \(duration(bar.seconds))") : tr("\(day) · \(duration(bar.seconds))")
    }

    /// 기간 단추에 커서를 대면: 그 기간의 날짜 (예: 11월 13일 ~ 오늘). 전체는 첫 세션 날부터
    static func rangeSpan(_ range: RangeTime.Range, first: Double?, now: Double) -> String {
        guard range != .today, let start = RangeTime.start(of: range, now: now) ?? first else { return day.string(from: Date(timeIntervalSince1970: now)) }
        return tr("\(day.string(from: Date(timeIntervalSince1970: start))) ~ 오늘")
    }

    static func rangeName(_ range: RangeTime.Range) -> String {
        switch range {
        case .today: tr("오늘")
        case .week: tr("7일")
        case .month: tr("30일")
        case .all: tr("전체")
        }
    }

    static func rangeNote(_ time: RangeTime, _ range: RangeTime.Range) -> String {
        range == .today ? tr("오늘 작업 시간") : tr("하루 평균 \(duration(time.dailyAverage)) · \(time.spanDays)일 중 \(time.workedDays)일")
    }

    /// 하루치 세션: 날짜와 그날 합계 한 줄, 그 아래 세션들
    private func dayGroup(_ day: Date, _ items: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(Self.dayLabel(day)) · \(Self.duration(items.reduce(0) { $0 + $1.activeSeconds }))")
                .font(Brand.font(.caption, .semibold)).foregroundStyle(Brand.ink).padding(.bottom, 4)
            ForEach(items) { sessionRow($0) }
        }
        .padding(.bottom, 22)
    }

    /// 세션 한 줄: 왼쪽에 시각과 길이, 오른쪽에 한 일 (최대 2줄, 전체는 커서를 대면). 다시 열기는 커서를 댈 때만
    private func sessionRow(_ session: SessionSummary) -> some View {
        let start = Date(timeIntervalSince1970: session.start)
        let range = Self.clock.string(from: start) + (session.end > session.start ? "–" + Self.clock.string(from: Date(timeIntervalSince1970: session.end)) : "")
        let lines = session.summaries.isEmpty ? [session.title] : session.summaries
        let hovered = hoveredSession == session.id
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(range).font(Brand.jost(12)).tracking(0.18).foregroundStyle(Brand.tabText)
                Text(Self.rowDuration(session.activeSeconds)).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
            }
            .frame(width: 84, alignment: .leading)
            Text(lines.prefix(2).joined(separator: "\n")).font(Brand.font(.body)).foregroundStyle(Brand.tabText).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(lines.joined(separator: "\n"))
            Button { state.prepareResume(sessionId: session.id) } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 11)).foregroundStyle(Brand.tabText)
            }
            .buttonStyle(.plain)
            .help(tr("다시 열기"))
            .accessibilityLabel(tr("다시 열기"))
            .opacity(hovered ? 1 : 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color(hex: 0xF6F4F2) : .clear))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredSession = session.id } else if hoveredSession == session.id { hoveredSession = nil }
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
    static var kinds: [(name: String, color: Color, items: KeyPath<TaskMaterials, [TaskMaterials.Item]>, opens: Opens)] { [
        (tr("참고자료"), Color(hex: 0x00929E), \.references, .resource),
        (tr("산출물"), Color(hex: 0xB48F3C), \.outputs, .resource),
        (tr("앱"), Color(hex: 0x915A95), \.apps, .app),
        (tr("주제"), Color(hex: 0x5A9E6A), \.topics, .none),
        (tr("문제"), Color(hex: 0xAB5242), \.problems, .none),
        (tr("나중에 할 일"), Color(hex: 0x6885C3), \.later, .none),
    ] }
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

}

/// 하루(또는 한 주) 작업 시간 막대: 가장 긴 칸이 꽉 찬 높이, 쉰 날은 바닥에 옅은 선
struct ActivityBars: View {
    let values: [Double]
    let color: Color
    let height: CGFloat
    /// 커서가 올라간 칸 (진하게)
    var highlight: Int? = nil
    /// 커서가 칸 위를 지날 때 그 칸 번호, 벗어나면 nil (없으면 커서를 따라가지 않음)
    var onHover: ((Int?) -> Void)? = nil

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: height > 20 ? 3 : 1.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index == highlight ? Brand.tabText : value > 0 ? color : Color(hex: 0xE2DDD8))
                    .frame(height: value > 0 ? max(2, height * value / top) : 1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: height)
        .overlay {
            if let onHover {
                // 칸 사이 틈에서도 끊기지 않게 막대 전체에서 커서 위치로 칸을 고른다
                GeometryReader { g in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        if case .active(let point) = phase, g.size.width > 0, !values.isEmpty {
                            onHover(min(values.count - 1, max(0, Int(point.x / g.size.width * CGFloat(values.count)))))
                        } else {
                            onHover(nil)
                        }
                    }
                }
            }
        }
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
