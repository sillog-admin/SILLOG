import Foundation
import GRDB

/// 사용 시간 기록 한 줄: 그날 그 업무가 그 대상(업무 자체·자료·앱·프로젝트)에 쓴 시간
public struct LedgerRow: Equatable, Sendable {
    public enum Kind: String, Sendable { case task, resource, app, project }

    public var day: String
    /// '' = 미배정·업무 외
    public var taskKey: String
    public var kind: Kind
    public var target: String
    public var seconds: Double
    public var firstAt: Double
    public var lastAt: Double
    public var hits: Int
    public var frozen: Bool

    public init(day: String, taskKey: String, kind: Kind, target: String, seconds: Double, firstAt: Double, lastAt: Double, hits: Int, frozen: Bool = false) {
        self.day = day; self.taskKey = taskKey; self.kind = kind; self.target = target; self.seconds = seconds
        self.firstAt = firstAt; self.lastAt = lastAt; self.hits = hits; self.frozen = frozen
    }
}

/// 업무 하나의 전체 합계 (재구성에서 업무 노드의 시간을 다시 채울 때)
public struct TaskTotal: Equatable, Sendable {
    public var seconds = 0.0
    public var lastAt = 0.0
    public var projects: [String: Double] = [:]
}

/// 원문(관측)에서 날 단위 사용 시간을 계산해 usage_ledger 에 둔다. 원문을 정리한 날은 동결해서 다시 계산하지 않는다
public struct LedgerBuilder {
    public let tally: ActivityTally
    public let calendar: PeriodCalendar

    public init(tally: ActivityTally = ActivityTally(), calendar: PeriodCalendar = PeriodCalendar()) {
        self.tally = tally; self.calendar = calendar
    }

    /// 원문에서 계산한 그날들의 행 (저장하지 않는다)
    public func compute(_ conn: Database, days: [String]) throws -> [LedgerRow] {
        let wanted = Set(days)
        guard let from = days.compactMap(calendar.dayStart).min(), let to = days.compactMap(calendar.dayEnd).max() else { return [] }
        let windows = try tally.windows(conn, overlapping: from..<to)
        guard !windows.isEmpty else { return [] }
        var keys: [Int64: String] = [:]
        for row in try Row.fetchAll(conn, sql: "SELECT id, key FROM nodes WHERE label = 'Task'") { keys[row["id"]] = row["key"] }

        struct Slot: Hashable { let day: String, task: String, kind: LedgerRow.Kind, target: String }
        var totals: [Slot: LedgerRow] = [:]
        func add(_ slot: Slot, _ seconds: Double, _ first: Double, _ last: Double) {
            if var row = totals[slot] {
                row.seconds += seconds; row.firstAt = min(row.firstAt, first); row.lastAt = max(row.lastAt, last); row.hits += 1
                totals[slot] = row
            } else {
                totals[slot] = LedgerRow(day: slot.day, taskKey: slot.task, kind: slot.kind, target: slot.target, seconds: seconds, firstAt: first, lastAt: last, hits: 1)
            }
        }
        for window in windows {
            for item in window.assignments {
                let row = item.row
                let task = item.taskId.flatMap { keys[$0] } ?? ""
                for share in tally.dayShares(row, in: window, calendar: calendar) where wanted.contains(share.day) {
                    let dayStart = calendar.dayStart(share.day) ?? row.start, dayEnd = calendar.dayEnd(share.day) ?? row.end
                    let first = min(max(row.start, dayStart), dayEnd), last = max(min(row.end, dayEnd), first)
                    add(Slot(day: share.day, task: task, kind: .task, target: task), share.seconds, first, last)
                    if !row.isChat { add(Slot(day: share.day, task: task, kind: .app, target: row.appBundle), share.seconds, first, last) }
                    // 업무 밖 행의 주소·파일은 영구 기록에 남기지 않는다 (사적인 탐색이 요약보다 오래 남지 않게)
                    guard !task.isEmpty, item.resource else { continue }
                    if let uri = row.uri, !uri.isEmpty, !TransientPages.isTransient(url: uri, title: row.title) {
                        add(Slot(day: share.day, task: task, kind: .resource, target: uri), share.seconds, first, last)
                    }
                    if let project = row.projectKey, share.seconds > 0 {
                        add(Slot(day: share.day, task: task, kind: .project, target: project), share.seconds, first, last)
                    }
                }
            }
        }
        return totals.values.sorted { ($0.day, $0.taskKey, $0.kind.rawValue, $0.target) < ($1.day, $1.taskKey, $1.kind.rawValue, $1.target) }
    }

    /// 동결된(원문을 정리한) 날
    public static func frozenDays(_ conn: Database, among days: [String]) throws -> Set<String> {
        guard !days.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: days.count).joined(separator: ",")
        return Set(try String.fetchAll(conn, sql: "SELECT DISTINCT day FROM usage_ledger WHERE frozen = 1 AND day IN (\(marks))",
                                       arguments: StatementArguments(days)))
    }

    /// 그날들을 원문에서 다시 계산해 저장한다. 동결된 날은 건드리지 않는다. 다시 계산한 날 수를 돌려준다
    @discardableResult
    public func refresh(_ conn: Database, days: [String]) throws -> Int {
        let frozen = try Self.frozenDays(conn, among: days)
        let open = days.filter { !frozen.contains($0) }
        guard !open.isEmpty else { return 0 }
        let rows = try compute(conn, days: open)
        for day in open { try conn.execute(sql: "DELETE FROM usage_ledger WHERE day = ? AND frozen = 0", arguments: [day]) }
        for row in rows {
            try conn.execute(sql: """
                INSERT INTO usage_ledger(day, task_key, target_kind, target_key, seconds, first_at, last_at, hits, frozen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                """, arguments: [row.day, row.taskKey, row.kind.rawValue, row.target, row.seconds, row.firstAt, row.lastAt, row.hits])
        }
        return open.count
    }

    /// 원문을 지우기 직전: 마지막으로 다시 계산하고 동결한다
    public func freeze(_ conn: Database, day: String) throws {
        try refresh(conn, days: [day])
        try conn.execute(sql: "UPDATE usage_ledger SET frozen = 1 WHERE day = ?", arguments: [day])
    }

    /// 기간의 행: 동결된 날은 저장값, 나머지 날은 원문에서 계산 (원문이 있든 없든 같은 수치)
    public func rows(_ conn: Database, days: [String]) throws -> [LedgerRow] {
        let frozen = try Self.frozenDays(conn, among: days)
        var result: [LedgerRow] = []
        if !frozen.isEmpty {
            let list = Array(frozen)
            let marks = Array(repeating: "?", count: list.count).joined(separator: ",")
            result = try Row.fetchAll(conn, sql: "SELECT * FROM usage_ledger WHERE frozen = 1 AND day IN (\(marks))", arguments: StatementArguments(list))
                .compactMap(Self.row)
        }
        return result + (try compute(conn, days: days.filter { !frozen.contains($0) }))
    }

    /// 업무별 전체 합계 (동결된 날 + 원문이 남은 날)
    public func taskTotals(_ conn: Database, now: Double) throws -> [String: TaskTotal] {
        var rows = try Row.fetchAll(conn, sql: "SELECT * FROM usage_ledger WHERE frozen = 1 AND task_key <> '' AND target_kind IN ('task', 'project')").compactMap(Self.row)
        if let earliest = try Double.fetchOne(conn, sql: "SELECT MIN(ts) FROM observations WHERE batch_id IS NOT NULL") {
            let days = calendar.days(from: earliest, to: max(now, earliest) + 86_400)
            let frozen = try Self.frozenDays(conn, among: days)
            rows += try compute(conn, days: days.filter { !frozen.contains($0) })
        }
        var totals: [String: TaskTotal] = [:]
        for row in rows where !row.taskKey.isEmpty {
            switch row.kind {
            case .task:
                totals[row.taskKey, default: TaskTotal()].seconds += row.seconds
                totals[row.taskKey, default: TaskTotal()].lastAt = max(totals[row.taskKey]?.lastAt ?? 0, row.lastAt)
            case .project:
                totals[row.taskKey, default: TaskTotal()].projects[row.target, default: 0] += row.seconds
            default: break
            }
        }
        return totals
    }

    static func row(_ row: Row) -> LedgerRow? {
        guard let kind = LedgerRow.Kind(rawValue: row["target_kind"]) else { return nil }
        return LedgerRow(day: row["day"], taskKey: row["task_key"], kind: kind, target: row["target_key"], seconds: row["seconds"],
                         firstAt: row["first_at"], lastAt: row["last_at"], hits: row["hits"], frozen: (row["frozen"] as Int) == 1)
    }
}
