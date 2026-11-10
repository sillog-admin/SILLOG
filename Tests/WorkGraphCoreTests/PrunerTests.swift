import XCTest
import GRDB
@testable import WorkGraphCore

private typealias F = ConsolidationFixtures

final class PrunerTests: XCTestCase {
    /// 9/28(W40): 보고서 작성(나중에도 쓰는 텍스트) + API 구현(그날만 있는 텍스트), 10/20(W43): 보고서 작성(같은 텍스트).
    /// 11/1 에 주간 요약을 서술 없이 확정한다 (유예는 그때부터 7일)
    private func seeded(_ db: WGDatabase? = nil) async throws -> (WGDatabase, TestClock) {
        let db = try db ?? F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 20, text: "공유되는 화면 텍스트")
        try await F.work(db, task: "API 구현", day: "2026-09-28", hour: 14, minutes: 20, text: "9월 28일에만 있는 텍스트")
        try await F.work(db, task: "보고서 작성", day: "2026-10-20", hour: 10, minutes: 20, text: "공유되는 화면 텍스트")
        let clock = TestClock(F.at("2026-11-01", 3))
        let report = await F.consolidator(db, clock: clock).run(prune: false, narrate: false)
        XCTAssertEqual(report.weekly, 3, "\(report)")
        return (db, clock)
    }

    private func consent(_ db: WGDatabase) throws {
        try db.writer.write { try ConsolidationStore.set(ConsolidationStore.Key.firstPruneConsentedAt, "1", $0) }
    }

    private func texts(_ db: WGDatabase) throws -> Set<String> {
        Set(try db.writer.read { try String.fetchAll($0, sql: "SELECT text FROM text_snapshots") })
    }

    func testNothingIsDeletedBeforeGraceAndConsent() async throws {
        let (db, clock) = try await seeded()
        let pruner = Pruner(db: db, ledger: F.ledger)
        var plan = try pruner.plan(now: clock.now)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.blockedReason?.contains("유예") ?? false, plan.blockedReason ?? "-")

        clock.now += 8 * 86_400
        plan = try pruner.plan(now: clock.now)
        XCTAssertEqual(plan.days.first?.day, "2026-09-28")
        XCTAssertEqual(plan.days.first?.categories, [.batchLog, .screenText])
        XCTAssertFalse(plan.days.contains { $0.day == "2026-10-20" && $0.categories.contains(.screenText) }, "보관 기간 안의 텍스트는 아니다")
        XCTAssertGreaterThan(plan.estimatedBytes, 0)
        XCTAssertTrue(plan.consentNeeded)
        XCTAssertThrowsError(try pruner.execute(plan, now: clock.now)) { XCTAssertEqual($0 as? PruneError, .consentRequired) }
        XCTAssertEqual(try texts(db).count, 2)
    }

    func testPruningRemovesOldTextKeepsSharedTextAndFreezesTheDay() async throws {
        let (db, clock) = try await seeded()
        clock.now += 8 * 86_400
        try consent(db)
        let before = try await db.writer.read { try F.ledger.rows($0, days: ["2026-09-28"]) }.filter { $0.kind == .task }.map(\.seconds).reduce(0, +)
        let pruner = Pruner(db: db, ledger: F.ledger)
        let result = try pruner.execute(try pruner.plan(now: clock.now), now: clock.now)
        XCTAssertEqual(result.sealedUntil, "2026-09-28")
        XCTAssertGreaterThan(result.counts[.screenText] ?? 0, 0)

        XCTAssertEqual(try texts(db), ["공유되는 화면 텍스트"], "다른 날이 참조하는 텍스트는 남는다")
        let (oldRefs, newRefs, observations) = try await db.writer.read { conn in
            (try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM observations WHERE ts < ? AND text_id IS NOT NULL", arguments: [F.at("2026-09-29", 0)]) ?? -1,
             try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM observations WHERE ts >= ? AND text_id IS NOT NULL", arguments: [F.at("2026-10-20", 0)]) ?? -1,
             try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM observations") ?? -1)
        }
        XCTAssertEqual(oldRefs, 0)
        XCTAssertEqual(newRefs, 20)
        XCTAssertEqual(observations, 60, "관측은 90일 보관")

        let frozen = try await db.writer.read { try LedgerBuilder.frozenDays($0, among: ["2026-09-28", "2026-10-20"]) }
        XCTAssertEqual(frozen, ["2026-09-28"])
        let after = try await db.writer.read { try F.ledger.rows($0, days: ["2026-09-28"]) }.filter { $0.kind == .task }.map(\.seconds).reduce(0, +)
        XCTAssertEqual(after, before, accuracy: 0.001)

        let batches = try await db.writer.read { try BatchRecord.fetchAll($0, sql: "SELECT * FROM batches ORDER BY started_at") }
        XCTAssertTrue(batches.allSatisfy { $0.userPrompt == nil && $0.rawResponse == nil }, "정리 기록 원문은 14일")
        XCTAssertTrue(batches.allSatisfy { $0.systemPromptHash != nil && $0.stats != nil }, "해시와 통계는 남는다")
        XCTAssertNil(batches.first?.llmPatch, "봉인된 날의 배치는 응답 패치까지 비운다")
        XCTAssertNotNil(batches.last?.llmPatch, "봉인 전 배치는 재구성을 위해 패치를 남긴다")
        let prunedUntil = try await db.writer.read { try ConsolidationStore.value(ConsolidationStore.Key.textPrunedUntil, $0) }
        XCTAssertEqual(prunedUntil, "2026-09-28")
    }

    func testDraftDigestBlocksPruningOfItsWeekAndLater() async throws {
        let (db, clock) = try await seeded()
        clock.now += 8 * 86_400
        try consent(db)
        try await db.writer.write { try $0.execute(sql: "UPDATE digests SET status = 'draft', verified_at = NULL WHERE period = '2026-W40'") }
        let plan = try Pruner(db: db, ledger: F.ledger).plan(now: clock.now)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.blockedReason?.contains("초안") ?? false, plan.blockedReason ?? "-")
    }

    func testFailedDigestKeepsItsWeekWhileLaterWeeksAreCleaned() async throws {
        let (db, clock) = try await seeded()
        clock.now += 28 * 86_400                          // 10/20 화면 텍스트도 보관 기간(30일)이 지났다
        try consent(db)
        try await db.writer.write {
            try $0.execute(sql: "UPDATE digests SET status = 'draft', verified_at = NULL, attempts = ? WHERE period = '2026-W40'", arguments: [DigestBuilder.maxAttempts])
        }
        let pruner = Pruner(db: db, ledger: F.ledger)
        var plan = try pruner.plan(now: clock.now)
        XCTAssertEqual(plan.days.map(\.day), ["2026-10-20"], "검증에 실패한 주는 건너뛰고 그 뒤 주는 정리한다")
        XCTAssertTrue(plan.days.first?.categories.contains(.screenText) ?? false)
        XCTAssertEqual(plan.keptWeeks, ["2026-W40"])
        XCTAssertTrue(plan.keptReasons.first?.contains("검증을 통과하지 못해") ?? false, plan.keptReasons.first ?? "-")
        XCTAssertNil(plan.blockedReason)
        let keptWeekTexts = { try await db.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE ts < ? AND text_id IS NOT NULL", arguments: [F.at("2026-09-29", 0)]) ?? 0
        } }
        let before = try await keptWeekTexts()
        try pruner.execute(plan, now: clock.now)
        XCTAssertEqual(try texts(db), ["공유되는 화면 텍스트", "9월 28일에만 있는 텍스트"], "남긴 주가 함께 쓰는 텍스트도 지우지 않는다")
        XCTAssertGreaterThan(before, 0)
        let after = try await keptWeekTexts()
        XCTAssertEqual(after, before, "남긴 주의 관측은 화면 텍스트를 그대로 가리킨다")

        // 사용자가 확인하고 저장하면 유예 기간 뒤 그 주도 정리한다
        let ids = try await db.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM digests WHERE period = '2026-W40'") }
        try await db.writer.write { conn in for id in ids { try DigestStore.edit(conn, id: id, body: "확인한 요약", now: clock.now) } }
        plan = try pruner.plan(now: clock.now)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.blockedReason?.contains("유예") ?? false, plan.blockedReason ?? "-")
        plan = try pruner.plan(now: clock.now + 8 * 86_400)
        XCTAssertEqual(plan.days.first?.day, "2026-09-28", "확인하고 저장한 요약은 유예 기간 뒤 원문을 대신한다")
        XCTAssertTrue(plan.keptWeeks.isEmpty)
    }

    func testTaskPinKeepsThatTasksTextAndPeriodPinSkipsTheDay() async throws {
        let (db, clock) = try await seeded()
        clock.now += 8 * 86_400
        try consent(db)
        let pinned = try F.taskKey(db, title: "API 구현")
        try await db.writer.write { try ConsolidationStore.pin(.task, key: pinned, at: 0, $0) }
        let pruner = Pruner(db: db, ledger: F.ledger)
        _ = try pruner.execute(try pruner.plan(now: clock.now), now: clock.now)
        XCTAssertEqual(try texts(db), ["공유되는 화면 텍스트", "9월 28일에만 있는 텍스트"], "핀이 걸린 업무의 텍스트는 남는다")

        let (other, _) = try await seeded(try F.makeDB())
        try consent(other)
        try await other.writer.write { try ConsolidationStore.pin(.period, key: RetentionPin.periodKey(from: "2026-09-28", to: "2026-09-28"), at: 0, $0) }
        let plan = try Pruner(db: other, ledger: F.ledger).plan(now: clock.now)
        XCTAssertFalse(plan.days.contains { $0.day == "2026-09-28" }, "기간 핀이 걸린 날은 건너뛴다")
        XCTAssertTrue(plan.days.contains { $0.day == "2026-10-20" }, "핀은 그 뒤의 날을 막지 않는다")
    }

    func testDeletingObservationsClearsReferencesAndRebuildKeepsSealedSessions() async throws {
        let (db, clock) = try await seeded()
        let firstID = try await db.writer.read { try Int64.fetchOne($0, sql: "SELECT MIN(id) FROM observations") }
        let firstObservation = try XCTUnwrap(firstID)
        try EventStore(db).insertFileEvent(FileEvent(ts: F.at("2026-09-28", 10, 5), path: "/Users/me/Downloads/a.pdf", kind: "created", observationId: firstObservation))
        var policy = RetentionPolicy.standard
        policy.setDays(.observations, 30)
        try await db.writer.write { [policy] in try policy.save($0) }
        clock.now += 8 * 86_400
        try consent(db)
        let apiKey = try F.taskKey(db, title: "API 구현")
        func apiTime() throws -> Double {
            try db.writer.read { try GraphTx($0).node(label: NodeLabel.task, key: apiKey)?.props["active_seconds"]?.doubleValue } ?? -1
        }
        let rebuilder = GraphRebuilder(db: db, store: EventStore(db), home: F.home, fileExists: { _ in false }, calendar: F.calendar)
        _ = try rebuilder.rebuildFromAssignments(now: clock.now)
        let timeBefore = try apiTime()
        let sessionsBefore = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nodes WHERE label = 'Session'") }

        let pruner = Pruner(db: db, ledger: F.ledger)
        let result = try pruner.execute(try pruner.plan(now: clock.now), now: clock.now)
        XCTAssertGreaterThan(result.counts[.observations] ?? 0, 0)
        let (oldObservations, link) = try await db.writer.read { conn in
            (try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM observations WHERE ts < ?", arguments: [F.at("2026-09-29", 0)]) ?? -1,
             try Int64.fetchOne(conn, sql: "SELECT observation_id FROM file_events"))
        }
        XCTAssertEqual(oldObservations, 0)
        XCTAssertNil(link, "파일 기록의 관측 참조는 먼저 비운다")

        _ = try rebuilder.rebuildFromAssignments(now: clock.now)
        XCTAssertEqual(try apiTime(), timeBefore, accuracy: 0.001, "원문을 지운 날의 업무 시간은 동결된 기록에서 온다")
        let sessionsAfter = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nodes WHERE label = 'Session'") }
        XCTAssertEqual(sessionsAfter, sessionsBefore, "봉인된 날의 세션은 재구성에서 지우지 않는다")
    }

    func testReclaimShrinksTheDatabaseFile() async throws {
        let db = try F.makeFileDB()
        for hour in 9..<15 {
            try await F.work(db, task: "자료 조사 \(hour)", day: "2026-09-28", hour: Double(hour), minutes: 20,
                             text: (0..<4000).map { "\(hour)번째 시간의 화면 글자 \($0)" }.joined(separator: " "))
        }
        let clock = TestClock(F.at("2026-11-01", 3))
        _ = await F.consolidator(db, clock: clock).run(prune: false, narrate: false)
        clock.now += 8 * 86_400
        try consent(db)
        let pruner = Pruner(db: db, ledger: F.ledger)
        _ = try pruner.execute(try pruner.plan(now: clock.now), now: clock.now)
        let reclaimed = try pruner.reclaimSpace(freeDiskBytes: .max)
        XCTAssertTrue(reclaimed.vacuumed, "처음에는 auto_vacuum 을 바꾸려고 전체 정리")
        XCTAssertLessThan(reclaimed.after, reclaimed.before, "\(reclaimed)")
        let mode = try await db.writer.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") }
        XCTAssertEqual(mode, 2)
        let again = try pruner.reclaimSpace(freeDiskBytes: .max)
        XCTAssertFalse(again.vacuumed, "그 뒤로는 incremental_vacuum 만")
    }
}

final class RetentionPolicyTests: XCTestCase {
    func testDefaultsAreTheTeamDecision() {
        let policy = RetentionPolicy.standard
        XCTAssertEqual(policy.screenTextDays, 30)
        XCTAssertEqual(policy.observationDays, 90)
        XCTAssertEqual(policy.screenCardDays, 180)
        XCTAssertEqual(policy.graceDays, 7)
        XCTAssertEqual(policy.preset, .standard)
    }

    func testObservationsNeverOutliveScreenTextLimits() {
        var policy = RetentionPolicy.standard
        policy.setDays(.screenText, 120)
        XCTAssertEqual(policy.observationDays, 120, "텍스트를 늘리면 관측도 따라 늘어난다")
        policy.setDays(.observations, 20)
        XCTAssertEqual(policy.screenTextDays, 20, "관측을 줄이면 텍스트도 따라 줄어든다")
        policy.apply(.keepRaw)
        XCTAssertNil(policy.screenTextDays)
        XCTAssertNil(policy.observationDays, "원문 무기한이면 관측도 지우지 않는다")
        policy.setDays(.screenCards, 1)
        XCTAssertEqual(policy.screenCardDays, RetentionPolicy.Item.screenCards.range.lowerBound)
        policy.graceDays = 99
        XCTAssertEqual(policy.normalized().graceDays, 30)
    }

    func testPolicyRoundTripsThroughTheDatabaseIncludingForever() throws {
        let db = try WGDatabase.inMemory()
        var policy = RetentionPolicy.standard
        policy.apply(.keepRaw)
        policy.narrateDigests = false
        try db.writer.write { try policy.save($0) }
        let loaded = try db.writer.read { try RetentionPolicy.load($0) }
        XCTAssertEqual(loaded, policy.normalized())
        XCTAssertNil(loaded.screenTextDays)
        XCTAssertEqual(loaded.preset, .keepRaw)
    }
}
