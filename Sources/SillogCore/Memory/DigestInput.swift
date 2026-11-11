import CryptoKit
import Foundation
import GRDB

/// 업무 하나·기간 하나의 다이제스트 재료. 수치는 사용 시간 기록, 문장 재료는 그래프와 원문에서 모은다.
/// 업무 외 행·제외 앱·비공개 창은 애초에 업무에 속하지 않으므로 들어오지 않는다
public struct DigestInput: Encodable, Sendable {
    public struct TaskInfo: Encodable, Sendable {
        public var key: String
        public var title: String
        public var goal: String?
        public var status: String
    }
    public struct Resource: Encodable, Sendable { public var key: String; public var title: String; public var time: String }
    public struct Session: Encodable, Sendable { public var date: String; public var summaries: [String] }
    public struct Problem: Encodable, Sendable {
        public var key: String
        public var text: String
        public var state: String
        public var resolvedBy: String?
        public var date: String
        enum CodingKeys: String, CodingKey { case key, text, state, date; case resolvedBy = "resolved_by" }
    }
    public struct Later: Encodable, Sendable { public var key: String; public var text: String; public var state: String; public var date: String }
    public struct File: Encodable, Sendable { public var key: String; public var name: String; public var origin: String?; public var date: String }
    public struct Request: Encodable, Sendable { public var key: String; public var time: String; public var text: String }
    public struct Card: Encodable, Sendable { public var key: String; public var activity: String; public var content: String }
    public struct Week: Encodable, Sendable {
        public var period: String
        public var summary: String
        public var progress: [String]
        public var problems: [String]
        public var openItems: [String]
        enum CodingKeys: String, CodingKey { case period, summary, progress, problems; case openItems = "open_items" }
    }

    public var level: PeriodCalendar.Level
    public var period: String
    public var from: String
    public var to: String
    public var task: TaskInfo
    /// 코드가 만든 시간 문구 ("약 6시간")
    public var time: String
    public var metrics: DigestMetrics
    public var resources: [Resource] = []
    public var sessions: [Session] = []
    public var problems: [Problem] = []
    public var laterItems: [Later] = []
    public var files: [File] = []
    public var requests: [Request] = []
    public var cards: [Card] = []
    /// 월간: 그 달에 걸친 주간 다이제스트
    public var weeks: [Week] = []
    /// 서술이 가리킬 수 있는 key
    public var anchors: [String] = []
    /// 완료의 근거로 인정하는 key (해결된 문제, 끝낸 할 일, 새 파일)
    public var evidence: [String] = []

    enum CodingKeys: String, CodingKey {
        case level, period, from, to, task, time, metrics, resources, sessions, problems, files, requests, cards, weeks, anchors, evidence
        case laterItems = "later_items"
    }

    /// 입력이 바뀌면 다시 만든다 (업무 병합·이름 변경, 늦게 도착한 배치)
    public func hash(promptVersion: Int) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data + Data("|v\(promptVersion)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// 기간에 활동한 업무 key (사용 시간 기록 기준, 업무 외 제외)
    public static func activeTasks(_ conn: Database, period: PeriodCalendar.Period, ledger: LedgerBuilder) throws -> [String] {
        let rows = try ledger.rows(conn, days: period.days)
        let keys = Set(rows.filter { $0.kind == .task && !$0.taskKey.isEmpty && ($0.seconds > 0 || $0.hits > 0) }.map(\.taskKey))
        let existing = Set(try String.fetchAll(conn, sql: "SELECT key FROM nodes WHERE label = 'Task'"))
        return keys.intersection(existing).sorted()
    }

    public static func build(_ conn: Database, period: PeriodCalendar.Period, taskKey: String, ledger: LedgerBuilder) throws -> DigestInput? {
        let tx = GraphTx(conn)
        guard let node = try tx.node(label: NodeLabel.task, key: taskKey) else { return nil }
        let calendar = ledger.calendar
        let shortDate: (Double) -> String = { ts in
            let day = calendar.day(ts).split(separator: "-").compactMap { Int($0) }
            return day.count == 3 ? "\(day[1])/\(day[2])" : calendar.day(ts)
        }
        let clockFormatter = DateFormatter()
        clockFormatter.locale = Locale(identifier: "en_US_POSIX"); clockFormatter.timeZone = calendar.timeZone; clockFormatter.dateFormat = "HH:mm"
        let start = period.start, end = period.end

        // 수치: 사용 시간 기록
        var metrics = DigestMetrics()
        let rows = try ledger.rows(conn, days: period.days).filter { $0.taskKey == taskKey }
        var perDay: [String: Double] = [:], perResource: [String: Double] = [:], perApp: [String: Double] = [:]
        for row in rows {
            switch row.kind {
            case .task: metrics.activeSeconds += row.seconds; perDay[row.day, default: 0] += row.seconds
            case .resource: perResource[row.target, default: 0] += row.seconds
            case .app: perApp[row.target, default: 0] += row.seconds
            case .project: break
            }
        }
        metrics.days = perDay.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { DigestMetrics.DayShare(day: $0.key, seconds: $0.value) }
        func title(_ label: String, _ key: String) throws -> String {
            try String.fetchOne(conn, sql: "SELECT title FROM nodes WHERE label = ? AND key = ?", arguments: [label, key]).flatMap { $0.isEmpty ? nil : $0 } ?? key
        }
        // AI 대화 세션처럼 시간이 없는 자료는 요청 목록으로 다룬다
        metrics.resources = try perResource.filter { $0.value >= 1 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(10)
            .map { DigestMetrics.Share(key: $0.key, title: String(try title(NodeLabel.resource, $0.key).prefix(90)), seconds: $0.value) }
        metrics.apps = try perApp.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)
            .map { DigestMetrics.Share(key: $0.key, title: try title(NodeLabel.app, $0.key), seconds: $0.value) }

        var input = DigestInput(level: period.level, period: period.id, from: period.days.first ?? "", to: period.days.last ?? "",
                                task: TaskInfo(key: taskKey, title: node.title, goal: node.props["goal"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                                               status: node.props["status"]?.stringValue ?? "active"),
                                time: TimePhrase.approx(metrics.activeSeconds), metrics: metrics)
        input.resources = metrics.resources.map { Resource(key: $0.key, title: $0.title, time: TimePhrase.approx($0.seconds)) }

        // 세션과 그 요약
        let sessionRows = try Row.fetchAll(conn, sql: """
            SELECT s.* FROM edges e JOIN nodes s ON s.id = e.src
            WHERE e.dst = ? AND e.type = 'PART_OF' AND s.label = 'Session'
              AND COALESCE(json_extract(s.props, '$.start'), s.created_at) < ? AND COALESCE(json_extract(s.props, '$.end'), s.updated_at) >= ?
            ORDER BY COALESCE(json_extract(s.props, '$.start'), s.created_at)
            """, arguments: [node.id, end, start]).map(GraphTx.node)
        input.metrics.sessions = sessionRows.count
        if period.level == .week {
            var budget = 40
            for session in sessionRows where budget > 0 {
                let lines = (session.props["summaries"]?.arrayValue?.compactMap(\.stringValue) ?? [session.props["summary"]?.stringValue].compactMap { $0 })
                    .filter { !$0.isEmpty }.prefix(budget).map { String($0.prefix(140)) }
                guard !lines.isEmpty else { continue }
                budget -= lines.count
                input.sessions.append(Session(date: shortDate(session.props["start"]?.doubleValue ?? session.createdAt), summaries: Array(lines)))
            }
        }

        // 문제: 이 기간 세션이 부딪힌 것
        if !sessionRows.isEmpty {
            let ids = sessionRows.map { String($0.id) }.joined(separator: ",")
            let problems = try Row.fetchAll(conn, sql: """
                SELECT DISTINCT p.* FROM edges h JOIN nodes p ON p.id = h.dst WHERE h.type = 'HIT' AND h.src IN (\(ids)) AND p.label = 'Problem'
                """).map(GraphTx.node)
            for problem in problems.prefix(10) {
                let solver = try Row.fetchOne(conn, sql: """
                    SELECT r.key, r.title FROM edges e JOIN nodes r ON r.id = e.dst WHERE e.src = ? AND e.type = 'RESOLVED_BY' LIMIT 1
                    """, arguments: [problem.id])
                let at = problem.props["at"]?.doubleValue ?? problem.createdAt
                if at >= start && at < end { input.metrics.problemsNew += 1 }
                if solver != nil { input.metrics.problemsResolved += 1; input.evidence.append(problem.key) }
                input.problems.append(Problem(key: problem.key, text: String(problem.title.prefix(200)), state: solver == nil ? "open" : "resolved",
                                              resolvedBy: solver.map { ($0["title"] as String?).flatMap { $0.isEmpty ? nil : $0 } ?? $0["key"] }, date: shortDate(at)))
            }
        }

        // 나중에 할 일: 이 기간에 생긴 것과 아직 남은 것
        let laterRows = try Row.fetchAll(conn, sql: """
            SELECT l.* FROM edges f JOIN nodes l ON l.id = f.src WHERE f.dst = ? AND f.type = 'FOR' AND l.label = 'LaterItem'
            """, arguments: [node.id]).map(GraphTx.node)
        var laters: [(item: Later, inPeriod: Bool)] = []
        for item in laterRows {
            let at = item.props["at"]?.doubleValue ?? item.createdAt
            guard at < end else { continue }
            let done = item.props["done"]?.boolValue ?? false
            let inPeriod = at >= start
            guard inPeriod || !done else { continue }
            if inPeriod { input.metrics.laterNew += 1 }
            if !done { input.metrics.laterOpen += 1 } else { input.evidence.append(item.key) }
            laters.append((Later(key: item.key, text: String(item.title.prefix(200)), state: done ? "done" : "open", date: shortDate(at)), inPeriod))
        }
        input.laterItems = laters.sorted { $0.inPeriod && !$1.inPeriod }.prefix(10).map(\.item)

        // 새 파일 (내려받은 파일: 그 업무의 행에서 생긴 것)
        let files = try Row.fetchAll(conn, sql: """
            SELECT f.path, f.origin_url, f.ts FROM file_events f JOIN observations o ON o.id = f.observation_id
            WHERE o.task_id = ? AND f.ts >= ? AND f.ts < ? ORDER BY f.ts
            """, arguments: [node.id, start, end])
        input.metrics.filesNew = files.count
        for file in files.prefix(10) {
            let path: String = file["path"]
            let key = "file:\(path)"
            input.files.append(File(key: key, name: (path as NSString).lastPathComponent, origin: file["origin_url"], date: shortDate(file["ts"])))
            input.evidence.append(key)
        }

        // AI 도구 요청
        input.metrics.aiRequests = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM chat_messages WHERE task_id = ? AND ts >= ? AND ts < ?",
                                                    arguments: [node.id, start, end]) ?? 0
        if period.level == .week {
            for row in try Row.fetchAll(conn, sql: "SELECT id, ts, text FROM chat_messages WHERE task_id = ? AND ts >= ? AND ts < ? ORDER BY ts LIMIT 15",
                                        arguments: [node.id, start, end]) {
                let ts: Double = row["ts"]
                let text = (row["text"] as String).split(whereSeparator: \.isNewline).joined(separator: " ")
                input.requests.append(Request(key: "chat:\(row["id"] as Int64)", time: "\(shortDate(ts)) \(clockFormatter.string(from: Date(timeIntervalSince1970: ts)))",
                                              text: String(text.prefix(200))))
            }
            // 이 업무 행을 덮은 화면 카드 (가장 많은 행을 덮은 것부터)
            for row in try Row.fetchAll(conn, sql: """
                SELECT c.id, c.activity, c.content, COUNT(o.id) AS n FROM screen_cards c JOIN observations o ON o.card_id = c.id
                WHERE o.task_id = ? AND o.ts >= ? AND o.ts < ? GROUP BY c.id ORDER BY n DESC, c.id LIMIT 8
                """, arguments: [node.id, start, end]) {
                input.cards.append(Card(key: "card:\(row["id"] as Int64)", activity: String((row["activity"] as String).prefix(120)),
                                        content: String((row["content"] as String).prefix(300))))
            }
        }

        // 월간: 그 달에 걸친 주간 다이제스트
        var weekAnchors: [String] = [], weekEvidence: [String] = []
        if period.level == .month {
            for week in calendar.weeks(overlapping: period) {
                guard let digest = try DigestStore.find(conn, level: .week, period: week.id, taskKey: taskKey) else { continue }
                input.weeks.append(Week(period: week.id, summary: digest.content.summary,
                                        progress: digest.content.progress.map(\.text), problems: digest.content.problems.map(\.text),
                                        openItems: digest.content.openItems.map(\.text)))
                weekAnchors += digest.anchors
                weekEvidence += digest.content.progress.filter { $0.status == "evidenced" }.flatMap(\.anchors)
            }
        }

        // 한 식으로 + 를 이으면 Swift 6.2 에서 타입 계산 시간 초과로 빌드가 멈춘다: 집합에 차례로 더한다 (결과는 같다)
        var anchors: Set<String> = [taskKey]
        anchors.formUnion(input.resources.map(\.key)); anchors.formUnion(input.problems.map(\.key)); anchors.formUnion(input.laterItems.map(\.key))
        anchors.formUnion(input.files.map(\.key)); anchors.formUnion(input.requests.map(\.key)); anchors.formUnion(input.cards.map(\.key))
        anchors.formUnion(weekAnchors)
        input.anchors = anchors.sorted()
        input.evidence = Array(Set(input.evidence + weekEvidence).intersection(input.anchors)).sorted()
        return input
    }
}
