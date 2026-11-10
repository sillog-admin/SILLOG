import Foundation
import GRDB

/// 다이제스트 본문의 구조 (LLM 출력 또는 코드가 만든 결정적 요약). 검증을 통과한 것만 저장한다
public struct DigestContent: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var text: String
        /// 진척: evidenced | in_progress | requested
        public var status: String?
        /// 문제: resolved | open
        public var state: String?
        public var anchors: [String]

        public init(text: String, status: String? = nil, state: String? = nil, anchors: [String]) {
            self.text = text; self.status = status; self.state = state; self.anchors = anchors
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status)
            state = try c.decodeIfPresent(String.self, forKey: .state)
            anchors = (try? c.decodeIfPresent([String].self, forKey: .anchors)) ?? []
        }
    }

    public struct NumberUse: Codable, Equatable, Sendable {
        public var name: String
        public var value: Double
    }

    public var summary: String
    public var progress: [Item]
    public var problems: [Item]
    public var openItems: [Item]
    public var decisions: [Item]
    public var numbersUsed: [NumberUse]

    public init(summary: String, progress: [Item] = [], problems: [Item] = [], openItems: [Item] = [], decisions: [Item] = [], numbersUsed: [NumberUse] = []) {
        self.summary = summary; self.progress = progress; self.problems = problems; self.openItems = openItems
        self.decisions = decisions; self.numbersUsed = numbersUsed
    }

    enum CodingKeys: String, CodingKey {
        case summary, progress, problems, decisions
        case openItems = "open_items"
        case numbersUsed = "numbers_used"
    }

    /// 빠진 목록은 빈 목록으로 (작은 모델의 흔들림)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        progress = (try? c.decodeIfPresent([Item].self, forKey: .progress)) ?? []
        problems = (try? c.decodeIfPresent([Item].self, forKey: .problems)) ?? []
        openItems = (try? c.decodeIfPresent([Item].self, forKey: .openItems)) ?? []
        decisions = (try? c.decodeIfPresent([Item].self, forKey: .decisions)) ?? []
        numbersUsed = (try? c.decodeIfPresent([NumberUse].self, forKey: .numbersUsed)) ?? []
    }

    var allItems: [Item] { progress + problems + openItems + decisions }
}

/// 사용 시간 기록에서 코드가 계산한 수치. 다이제스트의 숫자는 모두 여기서 온다
public struct DigestMetrics: Codable, Equatable, Sendable {
    public struct Share: Codable, Equatable, Sendable {
        public var key: String
        public var title: String
        public var seconds: Double
        public init(key: String, title: String, seconds: Double) { self.key = key; self.title = title; self.seconds = seconds }
    }
    public struct DayShare: Codable, Equatable, Sendable {
        public var day: String
        public var seconds: Double
        public init(day: String, seconds: Double) { self.day = day; self.seconds = seconds }
    }

    public var activeSeconds = 0.0
    public var days: [DayShare] = []
    public var resources: [Share] = []
    public var apps: [Share] = []
    public var sessions = 0
    public var aiRequests = 0
    public var problemsNew = 0
    public var problemsResolved = 0
    public var laterNew = 0
    public var laterOpen = 0
    public var filesNew = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case days, resources, apps, sessions
        case activeSeconds = "active_seconds"
        case aiRequests = "ai_requests"
        case problemsNew = "problems_new"
        case problemsResolved = "problems_resolved"
        case laterNew = "later_new"
        case laterOpen = "later_open"
        case filesNew = "files_new"
    }

    /// 두 업무를 합칠 때 (원문이 정리돼 다시 만들 수 없는 기간)
    func adding(_ other: DigestMetrics) -> DigestMetrics {
        var merged = self
        merged.activeSeconds += other.activeSeconds
        var days: [String: Double] = [:]
        for share in self.days + other.days { days[share.day, default: 0] += share.seconds }
        merged.days = days.sorted { $0.key < $1.key }.map { DayShare(day: $0.key, seconds: $0.value) }
        func combine(_ a: [Share], _ b: [Share], limit: Int) -> [Share] {
            var totals: [String: Share] = [:]
            for share in a + b {
                if var existing = totals[share.key] { existing.seconds += share.seconds; totals[share.key] = existing } else { totals[share.key] = share }
            }
            return Array(totals.values.sorted { ($0.seconds, $1.key) > ($1.seconds, $0.key) }.prefix(limit))
        }
        merged.resources = combine(resources, other.resources, limit: 10)
        merged.apps = combine(apps, other.apps, limit: 5)
        merged.sessions += other.sessions; merged.aiRequests += other.aiRequests
        merged.problemsNew += other.problemsNew; merged.problemsResolved += other.problemsResolved
        merged.laterNew += other.laterNew; merged.laterOpen += other.laterOpen; merged.filesNew += other.filesNew
        return merged
    }
}

/// 업무 하나의 주간·월간 요약
public struct Digest: Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// 서술 생성이 실패해 결정적 요약으로 대신한 상태. 이 기간의 원문은 지우지 않는다
        case draft
        case verified
        /// 사용자가 고친 것. 자동으로 다시 만들지 않는다
        case edited
    }

    public var id: Int64?
    public var level: PeriodCalendar.Level
    public var period: String
    public var periodStart: Double
    public var periodEnd: Double
    public var tz: String
    public var taskKey: String
    public var title: String
    public var body: String
    public var content: DigestContent
    public var metrics: DigestMetrics
    public var anchors: [String]
    public var status: Status
    public var model: String?
    public var promptVersion: Int
    public var inputHash: String
    public var attempts: Int
    public var createdAt: Double
    public var verifiedAt: Double?

    public init(id: Int64? = nil, level: PeriodCalendar.Level, period: String, periodStart: Double, periodEnd: Double, tz: String, taskKey: String,
                title: String, body: String, content: DigestContent, metrics: DigestMetrics, anchors: [String], status: Status, model: String?,
                promptVersion: Int, inputHash: String, attempts: Int, createdAt: Double, verifiedAt: Double?) {
        self.id = id; self.level = level; self.period = period; self.periodStart = periodStart; self.periodEnd = periodEnd; self.tz = tz
        self.taskKey = taskKey; self.title = title; self.body = body; self.content = content; self.metrics = metrics; self.anchors = anchors
        self.status = status; self.model = model; self.promptVersion = promptVersion; self.inputHash = inputHash; self.attempts = attempts
        self.createdAt = createdAt; self.verifiedAt = verifiedAt
    }

    public static func title(level: PeriodCalendar.Level, task: String, period: String) -> String {
        "\(level == .week ? "주간 요약" : "월간 요약") · \(task) · \(period)"
    }
}

/// 다이제스트 저장·조회·수정
public enum DigestStore {
    public static func find(_ conn: Database, level: PeriodCalendar.Level, period: String, taskKey: String) throws -> Digest? {
        try Row.fetchOne(conn, sql: "SELECT * FROM digests WHERE level = ? AND period = ? AND task_key = ?",
                         arguments: [level.rawValue, period, taskKey]).flatMap(Self.digest)
    }

    public static func digest(_ conn: Database, id: Int64) throws -> Digest? {
        try Row.fetchOne(conn, sql: "SELECT * FROM digests WHERE id = ?", arguments: [id]).flatMap(Self.digest)
    }

    /// 그 업무의 다이제스트, 최근 기간 먼저
    public static func list(_ conn: Database, taskKey: String) throws -> [Digest] {
        try Row.fetchAll(conn, sql: "SELECT * FROM digests WHERE task_key = ? ORDER BY period_start DESC, level DESC", arguments: [taskKey]).compactMap(Self.digest)
    }

    /// 최근 기간 순 (period 를 주면 그 기간만)
    public static func recent(_ conn: Database, period: String? = nil, limit: Int = 50) throws -> [Digest] {
        if let period {
            return try Row.fetchAll(conn, sql: "SELECT * FROM digests WHERE period = ? ORDER BY task_key", arguments: [period]).compactMap(Self.digest)
        }
        return try Row.fetchAll(conn, sql: "SELECT * FROM digests ORDER BY period_start DESC, level DESC, task_key LIMIT ?", arguments: [limit]).compactMap(Self.digest)
    }

    /// 기간의 다이제스트 (업무 key → 다이제스트)
    public static func byTask(_ conn: Database, level: PeriodCalendar.Level, period: String) throws -> [String: Digest] {
        var result: [String: Digest] = [:]
        for row in try Row.fetchAll(conn, sql: "SELECT * FROM digests WHERE level = ? AND period = ?", arguments: [level.rawValue, period]) {
            if let digest = digest(row) { result[digest.taskKey] = digest }
        }
        return result
    }

    @discardableResult
    public static func save(_ conn: Database, _ digest: Digest) throws -> Int64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let content = String(decoding: try encoder.encode(digest.content), as: UTF8.self)
        let metrics = String(decoding: try encoder.encode(digest.metrics), as: UTF8.self)
        let anchors = String(decoding: try encoder.encode(digest.anchors), as: UTF8.self)
        let id = try Int64.fetchOne(conn, sql: """
            INSERT INTO digests(level, period, period_start, period_end, tz, task_key, title, body, structured, metrics, anchors, status, model,
                                prompt_version, input_hash, attempts, created_at, verified_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(level, period, task_key) DO UPDATE SET
              period_start = excluded.period_start, period_end = excluded.period_end, tz = excluded.tz, title = excluded.title,
              body = excluded.body, structured = excluded.structured, metrics = excluded.metrics, anchors = excluded.anchors,
              status = excluded.status, model = excluded.model, prompt_version = excluded.prompt_version, input_hash = excluded.input_hash,
              attempts = excluded.attempts, verified_at = excluded.verified_at
            RETURNING id
            """, arguments: [digest.level.rawValue, digest.period, digest.periodStart, digest.periodEnd, digest.tz, digest.taskKey, digest.title,
                             digest.body, content, metrics, anchors, digest.status.rawValue, digest.model, digest.promptVersion, digest.inputHash,
                             digest.attempts, digest.createdAt, digest.verifiedAt])
        guard let id else { throw DatabaseError(message: "다이제스트를 저장하지 못함") }
        return id
    }

    /// 사용자가 본문을 고친다. 이후 자동으로 다시 만들지 않고, 고친 때부터 검증된 것으로 본다
    public static func edit(_ conn: Database, id: Int64, body: String, now: Double) throws {
        try conn.execute(sql: "UPDATE digests SET body = ?, status = 'edited', verified_at = COALESCE(verified_at, ?) WHERE id = ?",
                         arguments: [body, now, id])
    }

    /// 업무 병합: key 를 옮긴다. 남는 업무에도 같은 기간 요약이 있으면, 원문이 남은 기간은 둘 다 지워 다시 만들고
    /// 원문이 정리된 기간은 두 요약을 합친다
    static func mergeTask(from victim: String, into keep: String, now: Double, _ conn: Database) throws {
        let keepTitle = try String.fetchOne(conn, sql: "SELECT title FROM nodes WHERE label = 'Task' AND key = ?", arguments: [keep]) ?? keep
        let calendar = PeriodCalendar()
        let boundary = try GraphRebuilder.sealBoundary(conn, calendar: calendar)
        for moving in try Row.fetchAll(conn, sql: "SELECT * FROM digests WHERE task_key = ?", arguments: [victim]).compactMap(Self.digest) {
            guard let movingId = moving.id else { continue }
            if var kept = try find(conn, level: moving.level, period: moving.period, taskKey: keep) {
                if moving.periodEnd <= boundary {
                    kept.metrics = kept.metrics.adding(moving.metrics)
                    kept.content.summary = String((kept.content.summary + " " + moving.content.summary).prefix(600))
                    kept.content.progress = Array((kept.content.progress + moving.content.progress).prefix(8))
                    kept.content.problems = Array((kept.content.problems + moving.content.problems).prefix(8))
                    kept.content.openItems = Array((kept.content.openItems + moving.content.openItems).prefix(8))
                    kept.content.decisions = Array((kept.content.decisions + moving.content.decisions).prefix(8))
                    kept.anchors = Array(Set(kept.anchors + moving.anchors)).sorted()
                    kept.body = kept.status == .edited ? kept.body + "\n\n" + moving.body : DigestRenderer.body(kept.content, metrics: kept.metrics)
                    kept.verifiedAt = [kept.verifiedAt, moving.verifiedAt].compactMap { $0 }.max()
                    if kept.status == .draft || moving.status == .draft { kept.status = .draft }
                    try save(conn, kept)
                } else {
                    try conn.execute(sql: "DELETE FROM digests WHERE id = ?", arguments: [kept.id])
                }
                try conn.execute(sql: "DELETE FROM digests WHERE id = ?", arguments: [movingId])
            } else {
                try conn.execute(sql: "UPDATE digests SET task_key = ?, title = ? WHERE id = ?",
                                 arguments: [keep, Digest.title(level: moving.level, task: keepTitle, period: moving.period), movingId])
            }
        }
    }

    static func digest(_ row: Row) -> Digest? {
        guard let level = PeriodCalendar.Level(rawValue: row["level"]), let status = Digest.Status(rawValue: row["status"]) else { return nil }
        let decoder = JSONDecoder()
        let content = (try? decoder.decode(DigestContent.self, from: Data((row["structured"] as String).utf8))) ?? DigestContent(summary: "")
        let metrics = (try? decoder.decode(DigestMetrics.self, from: Data((row["metrics"] as String).utf8))) ?? DigestMetrics()
        let anchors = (try? decoder.decode([String].self, from: Data((row["anchors"] as String).utf8))) ?? []
        return Digest(id: row["id"], level: level, period: row["period"], periodStart: row["period_start"], periodEnd: row["period_end"],
                      tz: row["tz"], taskKey: row["task_key"], title: row["title"], body: row["body"], content: content, metrics: metrics,
                      anchors: anchors, status: status, model: row["model"], promptVersion: row["prompt_version"], inputHash: row["input_hash"],
                      attempts: row["attempts"], createdAt: row["created_at"], verifiedAt: row["verified_at"])
    }
}

/// 구조와 수치에서 Markdown 본문을 만든다. 시간 문구는 코드가 쓴다
public enum DigestRenderer {
    static func statusLabel(_ status: String?) -> String {
        switch status {
        case "evidenced": "근거 있음"
        case "requested": "요청됨"
        default: "진행 중"
        }
    }

    public static func body(_ content: DigestContent, metrics: DigestMetrics) -> String {
        var blocks: [String] = []
        if !content.summary.isEmpty { blocks.append("**요약** \(content.summary)") }
        func list(_ title: String, _ items: [DigestContent.Item], _ label: (DigestContent.Item) -> String?) {
            guard !items.isEmpty else { return }
            blocks.append("**\(title)**\n" + items.map { item in "- " + (label(item).map { "[\($0)] " } ?? "") + item.text }.joined(separator: "\n"))
        }
        list("한 일", content.progress) { statusLabel($0.status) }
        list("문제", content.problems) { $0.state == "resolved" ? "해결" : "미해결" }
        list("남은 일", content.openItems) { _ in nil }
        list("결정", content.decisions) { _ in nil }
        var numbers = ["작업 \(TimePhrase.approx(metrics.activeSeconds))"]
        if metrics.sessions > 0 { numbers.append("세션 \(metrics.sessions)개") }
        if metrics.aiRequests > 0 { numbers.append("AI 도구 요청 \(metrics.aiRequests)건") }
        var facts = "**수치** " + numbers.joined(separator: " · ")
        if !metrics.resources.isEmpty {
            facts += "\n- 많이 쓴 자료: " + metrics.resources.prefix(5).map { "\($0.title) (\(TimePhrase.approx($0.seconds)))" }.joined(separator: ", ")
        }
        blocks.append(facts)
        return blocks.joined(separator: "\n\n")
    }
}
