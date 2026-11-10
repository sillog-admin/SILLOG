import XCTest
import GRDB
@testable import WorkGraphCore

private typealias F = ConsolidationFixtures

final class LedgerTests: XCTestCase {
    func testLedgerTaskTotalsMatchSessionTimeAfterRebuild() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 50, url: "https://docs.example.com/report")
        try await F.work(db, task: "API 구현", day: "2026-09-28", hour: 14, minutes: 40)
        try await F.work(db, task: "보고서 작성", day: "2026-09-29", hour: 9, minutes: 20, url: "https://docs.example.com/report")
        let now = F.at("2026-10-01", 12)
        _ = try GraphRebuilder(db: db, store: EventStore(db), home: F.home, fileExists: { _ in false }, calendar: F.calendar).rebuildFromAssignments(now: now)

        let (totals, sessionSeconds, taskSeconds) = try await db.writer.read { conn in
            let totals = try F.ledger.taskTotals(conn, now: now)
            var sessions: [String: Double] = [:]
            for row in try Row.fetchAll(conn, sql: """
                SELECT t.key, SUM(json_extract(s.props, '$.active_seconds')) AS seconds FROM nodes s
                JOIN edges e ON e.src = s.id AND e.type = 'PART_OF' JOIN nodes t ON t.id = e.dst
                WHERE s.label = 'Session' GROUP BY t.key
                """) { sessions[row["key"]] = row["seconds"] }
            var tasks: [String: Double] = [:]
            for task in try GraphTx(conn).nodes(label: NodeLabel.task) { tasks[task.key] = task.props["active_seconds"]?.doubleValue }
            return (totals, sessions, tasks)
        }
        XCTAssertEqual(totals.count, 2)
        for (key, total) in totals {
            XCTAssertEqual(total.seconds, sessionSeconds[key] ?? -1, accuracy: 0.001, "사용 시간 기록 합계 = 세션 합계")
            XCTAssertEqual(total.seconds, taskSeconds[key] ?? -1, accuracy: 0.001, "업무 시간도 같은 값")
        }
    }

    func testRefreshIsIdempotentAndKeepsAddressesOnlyForTasks() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 20, url: "https://docs.example.com/report")
        try await F.work(db, task: nil, day: "2026-09-28", hour: 20, minutes: 15, app: "Safari", url: "https://video.example.com/watch")
        let read: () async throws -> [LedgerRow] = {
            try await db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM usage_ledger ORDER BY day, task_key, target_kind, target_key").compactMap(LedgerBuilder.row) }
        }
        try await db.writer.write { _ = try F.ledger.refresh($0, days: ["2026-09-28"]) }
        let first = try await read()
        try await db.writer.write { _ = try F.ledger.refresh($0, days: ["2026-09-28"]) }
        let second = try await read()
        XCTAssertEqual(second, first, "같은 날을 두 번 갱신해도 같다")

        XCTAssertTrue(first.contains { $0.taskKey.isEmpty && $0.kind == .task && $0.seconds > 0 }, "업무 외 시간은 남는다")
        XCTAssertTrue(first.contains { $0.taskKey.isEmpty && $0.kind == .app && $0.target == "com.test.Safari" })
        XCTAssertFalse(first.contains { $0.taskKey.isEmpty && $0.kind == .resource }, "업무 외 행의 주소는 영구 기록에 남기지 않는다")
        XCTAssertTrue(first.contains { !$0.taskKey.isEmpty && $0.kind == .resource && $0.target.contains("docs.example.com") })
    }

    func testRowAcrossMidnightIsSplitByActiveTime() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "야간 작업", day: "2026-09-28", hour: 23, minute: 40, minutes: 40)
        let rows = try await db.writer.read { try F.ledger.compute($0, days: ["2026-09-28", "2026-09-29"]) }.filter { $0.kind == .task }
        let first = rows.first { $0.day == "2026-09-28" }?.seconds ?? 0, second = rows.first { $0.day == "2026-09-29" }?.seconds ?? 0
        XCTAssertEqual(first, 20 * 60, accuracy: 1, "자정 전 20분")
        XCTAssertEqual(second, 19 * 60 + 90, accuracy: 1, "자정 뒤 19분 + 마지막 관측의 최대 간격")
        XCTAssertLessThanOrEqual(rows.first { $0.day == "2026-09-28" }?.lastAt ?? .infinity, F.calendar.dayEnd("2026-09-28")!)
    }

    func testFrozenDayKeepsValuesAfterRawRecordsAreGone() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 30)
        let before = try await db.writer.write { conn -> [LedgerRow] in
            try F.ledger.freeze(conn, day: "2026-09-28")
            return try F.ledger.rows(conn, days: ["2026-09-28"])
        }
        XCTAssertTrue(before.allSatisfy(\.frozen))
        try await db.writer.write { conn in
            try conn.execute(sql: "DELETE FROM observations")
            _ = try F.ledger.refresh(conn, days: ["2026-09-28"])
        }
        let after = try await db.writer.read { try F.ledger.rows($0, days: ["2026-09-28"]) }
        XCTAssertEqual(after.map(\.seconds).reduce(0, +), before.map(\.seconds).reduce(0, +), accuracy: 0.001, "동결된 날은 다시 계산하지 않는다")
        XCTAssertFalse(after.isEmpty)
    }

    func testCalendarUsesIsoWeeksAndLocalDays() {
        let monday = F.at("2026-09-28", 0, 30)
        XCTAssertEqual(F.calendar.week(containing: monday).id, "2026-W40")
        XCTAssertEqual(F.calendar.week(containing: monday).days.first, "2026-09-28")
        XCTAssertEqual(F.calendar.week(containing: monday).days.count, 7)
        XCTAssertEqual(F.calendar.period(id: "2026-W40")?.start, F.calendar.dayStart("2026-09-28"))
        XCTAssertEqual(F.calendar.period(id: "2026-10")?.days.count, 31)
        XCTAssertEqual(F.calendar.weeks(overlapping: F.calendar.period(id: "2026-10")!).count, 5)
        XCTAssertEqual(TimePhrase.approx(6 * 3600 + 20 * 60), "약 6시간 20분")
    }
}
