import Foundation

/// 행 하나의 판단 결과: 어느 업무인가, 그 행의 파일·페이지가 그 업무의 자료인가
public struct RowAssignment: Equatable, Sendable {
    public var row: ActivityRow
    public var taskId: Int64?
    public var resource: Bool
    /// 어떤 목표에도 기여하지 않는 행 (집중 이탈). 업무·세션·자료를 만들지 않고 시간만 남는다
    public var offTask: Bool
    /// LLM 이 적은 판정 이유 (한 구절)
    public var reason: String?
    public init(row: ActivityRow, taskId: Int64?, resource: Bool = true, offTask: Bool = false, reason: String? = nil) {
        self.row = row; self.taskId = taskId; self.resource = resource; self.offTask = offTask; self.reason = reason
    }
}

/// 세션 = 같은 업무의 행이 시간순으로 이어진 구간. 업무를 정하는 데는 쓰이지 않고, 정해진 행을 시간으로 묶어 보여 주는 것이다.
///   - 같은 업무가 gap(30분) 안에 다시 나오면 같은 세션으로 잇는다
///   - 다른 업무가 끼어들어도 세션은 갈리지 않는다 (끼어든 업무는 제 세션을 갖고, 흐름은 SWITCHED_TO 로 남는다)
///   - glance(1분) 미만 훑어본 행은 새 세션을 만들지 않고 같은 날 같은 업무의 가장 가까운 세션에 붙인다 (그 세션의 시간 범위가 넓어지고, 활동 시간은 실제만큼).
///     단 이 정리 안에서 바로(30분 안) 같은 업무의 진짜 작업이 이어지면 그 작업과 같은 세션이다. AI 에게 한 말(활동 0초)은 작업의 시작이라 훑어보기가 아니다.
///     붙인 훑어보기는 세션의 끝(end)만 늘리고 작업이 끝난 때(work_end)는 그대로라, 30분 규칙은 실제 작업 기준으로 잰다
/// LLM 없이 행 판단(observations.task_id)에서 언제든 다시 계산할 수 있다.
public struct SessionBuilder: Sendable {
    public struct Stats: Equatable, Sendable {
        public var sessions = 0, sessionsExtended = 0, resources = 0
        public init() {}
    }

    public var gap: Double = 1_800
    /// 이보다 짧게(초) 본 행은 같은 날 세션에 붙인다 (11/06: 세션 654개 중 387개가 1분 미만이었다)
    public var glance: Double = 60
    /// '같은 날'을 정하는 달력
    public var calendar: Calendar = .current

    public init(gap: Double = 1_800, glance: Double = 60, calendar: Calendar = .current) {
        self.gap = gap; self.glance = glance; self.calendar = calendar
    }

    /// 같은 날 그 업무의 세션 중 at 에 가장 가까운 것
    func sameDaySession(task: Int64, at: Double, tx: GraphTx) throws -> Int64? {
        let day = Date(timeIntervalSince1970: at)
        var best: (id: Int64, distance: Double)?
        for edge in try tx.edges(to: task, type: EdgeType.partOf) {
            guard let session = try tx.node(id: edge.src), session.label == NodeLabel.session,
                  let start = session.props["start"]?.doubleValue else { continue }
            let end = session.props["end"]?.doubleValue ?? start
            guard calendar.isDate(Date(timeIntervalSince1970: start), inSameDayAs: day) || calendar.isDate(Date(timeIntervalSince1970: end), inSameDayAs: day) else { continue }
            let distance = at < start ? start - at : at > end ? at - end : 0
            if best == nil || distance < best!.distance { best = (session.id, distance) }
        }
        return best?.id
    }

    /// 세션 제목: "9/22 14:45–20:01 · 업무 제목"
    static func title(task: String, start: Double, end: Double) -> String {
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "M/d HH:mm"
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.dateFormat = "HH:mm"
        return "\(day.string(from: Date(timeIntervalSince1970: start)))–\(clock.string(from: Date(timeIntervalSince1970: end))) · \(task)"
    }

    /// 행들을 세션에 반영한다. summaries: 업무 id → 이 행들에서 한 일 (세션 요약). 돌려주는 값: 행 번호 → 세션 id
    @discardableResult
    public func apply(_ assignments: [RowAssignment], summaries: [Int64: String], tx: GraphTx, stats: inout Stats) throws -> [Int: Int64] {
        let ordered = assignments.filter { $0.taskId != nil }.sorted { ($0.row.start, $0.row.row) < ($1.row.start, $1.row.row) }
        var sessionOf: [Int64: Int64] = [:]            // 업무 → 이번에 쓰는 세션
        var sessionByRow: [Int: Int64] = [:]
        var resourceKeys = Set<String>()
        var previousSession: Int64?

        func isGlance(_ item: RowAssignment) -> Bool { !item.row.isChat && Double(item.row.dwell) < glance }
        for (index, item) in ordered.enumerated() {
            guard let taskId = item.taskId, let task = try tx.node(id: taskId) else { continue }
            let row = item.row
            // 이 정리 안에서 30분 안에 같은 업무의 진짜 작업이 이어지는지 (그러면 훑어보기도 그 작업과 같은 세션)
            let workFollows = ordered[(index + 1)...].contains { $0.taskId == taskId && !isGlance($0) && $0.row.start - row.end <= gap }
            var attachedGlance = false
            let sessionId: Int64
            if let known = sessionOf[taskId] {
                sessionId = known
            } else if let latest = try tx.latestSession(ofTask: taskId),
                      let latestEnd = latest.props["work_end"]?.doubleValue ?? latest.props["end"]?.doubleValue,
                      row.start - latestEnd <= gap, row.start >= (latest.props["start"]?.doubleValue ?? 0) - gap {
                sessionId = latest.id
                stats.sessionsExtended += 1
            } else if isGlance(item), !workFollows, let sameDay = try sameDaySession(task: taskId, at: row.start, tx: tx) {
                sessionId = sameDay                                         // 혼자 훑어본 행: 같은 날 세션에 (이 업무의 다음 행이 이 세션으로 끌려오지 않게 기억하지 않는다)
                attachedGlance = true
                stats.sessionsExtended += 1
            } else {
                sessionId = try tx.upsertNode(label: NodeLabel.session, key: "s_\(task.key)_\(Int(row.start))", subtype: nil,
                                              title: Self.title(task: task.title, start: row.start, end: row.end),
                                              props: ["start": .number(row.start), "end": .number(row.end), "active_seconds": .number(0),
                                                      "summary": .string(""), "summaries": .array([])], at: row.start)
                try tx.upsertEdge(src: sessionId, dst: taskId, type: EdgeType.partOf, props: [:], addWeight: 0, at: row.start)
                stats.sessions += 1
            }
            if !attachedGlance { sessionOf[taskId] = sessionId }
            sessionByRow[row.row] = sessionId

            // 시간 범위, 실제 작업 시간, 요약(배치마다 한 문장씩 누적 — 덮어쓰면 마지막 5분만 남는다)
            if let session = try tx.node(id: sessionId) {
                let start = min(session.props["start"]?.doubleValue ?? row.start, row.start)
                let end = max(session.props["end"]?.doubleValue ?? row.end, row.end)
                var props: [String: JSONValue] = [
                    "start": .number(start), "end": .number(end),
                    "active_seconds": .number((session.props["active_seconds"]?.doubleValue ?? 0) + Double(row.dwell)),
                ]
                // 실제 작업이 끝난 때: 붙인 훑어보기는 늘리지 않는다 (예전 세션은 end 에서 시작)
                let workEnd = session.props["work_end"]?.doubleValue ?? session.props["end"]?.doubleValue ?? row.end
                props["work_end"] = .number(attachedGlance ? workEnd : max(workEnd, row.end))
                if let summary = summaries[taskId], !summary.isEmpty {
                    var list = session.props["summaries"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    if !list.contains(summary) { list.append(summary) }
                    props["summaries"] = .array(list.suffix(40).map { .string($0) })
                    props["summary"] = .string(summary)                      // 가장 최근 것 (업무 후보 목록의 recent work 용)
                }
                try tx.upsertNode(label: NodeLabel.session, key: session.key, subtype: nil,
                                  title: Self.title(task: task.title, start: start, end: end), props: props, at: row.end)
            }

            // 앱
            if !row.isChat {
                let appId = try tx.upsertNode(label: NodeLabel.app, key: row.appBundle, subtype: nil, title: row.app, props: [:], at: row.end)
                try tx.upsertEdge(src: sessionId, dst: appId, type: EdgeType.used, props: [:], addWeight: Double(row.dwell), at: row.end)
            }
            // 자료 (보이기만 한 것, 검색 결과·빈 탭·로그인 같은 지나가는 페이지는 제외)
            if item.resource, let uri = row.uri, !uri.isEmpty, !TransientPages.isTransient(url: uri, title: row.title) {
                let resourceId = try tx.upsertNode(label: NodeLabel.resource, key: uri, subtype: row.type, title: row.title,
                                                   props: ["last_seen": .number(row.end)], at: row.end)
                if resourceKeys.insert(uri).inserted { stats.resources += 1 }
                try tx.upsertEdge(src: sessionId, dst: resourceId, type: EdgeType.touched, props: [:], addWeight: Double(row.dwell), at: row.end)
                if let type = row.type, let typeNode = try tx.node(label: NodeLabel.resourceType, key: type) {
                    try tx.upsertEdge(src: resourceId, dst: typeNode.id, type: EdgeType.instanceOf, props: [:], addWeight: 0, at: row.end, countHit: false)
                }
                if let projectKey = row.projectKey {
                    let projectId = try tx.upsertNode(label: NodeLabel.project, key: projectKey, subtype: nil,
                                                      title: row.projectTitle ?? projectKey, props: [:], at: row.end)
                    try tx.upsertEdge(src: resourceId, dst: projectId, type: EdgeType.belongsTo, props: [:], addWeight: 0, at: row.end, countHit: false)
                }
            }

            // 흐름: 직전 행의 세션에서 이 세션으로
            if previousSession == nil, let before = try tx.latestSession(startedBefore: row.start, excluding: sessionId),
               (before.props["end"]?.doubleValue ?? 0) >= row.start - gap {
                previousSession = before.id
            }
            if let previous = previousSession, previous != sessionId {
                try tx.upsertEdge(src: previous, dst: sessionId, type: EdgeType.switchedTo, props: ["kind": .string("unknown")], addWeight: 0, at: row.start)
            }
            previousSession = sessionId
        }
        return sessionByRow
    }
}
