import XCTest
@testable import SillogCore

/// 화면 글자 줄이기: 편집기는 앞부분만 (내용은 파일에 있다), 업무 외로 판정된 행의 글자는 정리 뒤 지운다
final class ScreenTextTests: XCTestCase {
    func testEditorsKeepOnlyTheFirstPart() {
        let long = String(repeating: "가", count: 15_000)
        XCTAssertEqual(ScreenText.trimmed(long, appBundle: "com.microsoft.VSCode", appName: "Code").count, ScreenText.editorLimit)
        XCTAssertEqual(ScreenText.trimmed(long, appBundle: "com.google.Chrome", appName: "Google Chrome").count, 15_000, "편집기가 아니면 그대로")
        XCTAssertEqual(ScreenText.trimmed("짧은 글", appBundle: "com.microsoft.VSCode", appName: "Code"), "짧은 글")
        XCTAssertEqual(ScreenText.editorLimit, 3_000)
    }

    func testOffTaskTextIsDroppedUnlessAnotherRowUsesIt() throws {
        let db = try SillogDatabase.inMemory()
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO text_snapshots(id, hash, source, text, created_at) VALUES (1, 'a', 'ax', '유튜브 추천 영상 목록', 0), (2, 'b', 'ax', '공유 글', 0), (3, 'c', 'ax', '과제 문서', 0)")
            try conn.execute(sql: """
                INSERT INTO observations(id, ts, trigger_kind, app_bundle, app_name, text_id, off_task) VALUES
                  (1, 10, 'app_activate', 'com.google.Chrome', 'YouTube', 1, 1),
                  (2, 20, 'app_activate', 'com.google.Chrome', 'YouTube', 2, 1),
                  (3, 30, 'app_activate', 'com.google.Chrome', 'Google Chrome', 2, 0),
                  (4, 40, 'app_activate', 'com.apple.Preview', 'Preview', 3, 0)
                """)
            let dropped = try ScreenText.dropOffTask(conn, observationIds: [1, 2, 4])
            XCTAssertEqual(dropped, 1)
        }
        try db.writer.read { conn in
            XCTAssertEqual(try Int64.fetchAll(conn, sql: "SELECT id FROM text_snapshots ORDER BY id"), [2, 3], "다른 행(업무)도 쓰는 글과 업무 행의 글은 남긴다")
            XCTAssertEqual(try Int64.fetchAll(conn, sql: "SELECT id FROM observations WHERE text_id IS NULL"), [1, 2], "업무 외 행은 글 연결을 끊는다")
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM text_snapshots_chat_fts WHERE text_snapshots_chat_fts MATCH '유튜브'"), 0, "검색 색인에서도 빠진다")
        }
    }

    /// 정리 한 번은 업무 외 행의 글자를 바로 지우지 않는다.
    func testBatchKeepsTextOfOffTaskRowsForNow() async throws {
        let db = try SillogDatabase.inMemory()
        let store = EventStore(db)
        let work = try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.todesktop.230313mzl4w4u92", appName: "Cursor", windowTitle: "TaskCard.tsx — dashboard"))
        let game = try store.insert(Observation(ts: 200, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "FC 27 하이라이트 - YouTube",
                                                url: "https://youtube.com/watch?v=abc"))
        _ = try store.insert(Observation(ts: 400, trigger: "app_activate", appBundle: "com.apple.Terminal", appName: "Terminal", windowTitle: "npm run dev"))
        try store.attach(observationId: work, textId: try store.upsertText("카드 컴포넌트 코드", source: "ax", at: 100), screenshotPath: nil)
        try store.attach(observationId: game, textId: try store.upsertText("추천 영상 목록과 댓글", source: "ax", at: 200), screenshotPath: nil)
        let llm = StubLLM([.success("""
            {"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성"}],"rows":[{"rows":"1","task":"A"},{"rows":"2","task":"off"},{"rows":"3","task":"A"}],
             "work":[{"task":"A","summary":"카드 구현","topics":["React"]}]}
            """)])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 450 })
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("정리 성공") }
        let texts = try await db.writer.read { try String.fetchAll($0, sql: "SELECT text FROM text_snapshots ORDER BY id") }
        XCTAssertEqual(texts, ["카드 컴포넌트 코드", "추천 영상 목록과 댓글"])
    }

    func testConsolidationRespectsConsentAndScreenTextRetention() async throws {
        let db = try SillogDatabase.inMemory()
        let day = 86_400.0, now = 1_793_923_200.0                       // 2026-11-06 09:00 (서울)
        try await db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO text_snapshots(id, hash, source, text, created_at) VALUES (1, 'a', 'ax', '35일 전 유튜브', 0), (2, 'b', 'ax', '어제 유튜브', 0), (3, 'c', 'ax', '40일 전 유튜브', 0)")
            try conn.execute(sql: """
                INSERT INTO observations(id, ts, trigger_kind, app_bundle, app_name, text_id, off_task) VALUES
                  (1, ?, 'app_activate', 'com.google.Chrome', 'YouTube', 1, 1),
                  (2, ?, 'app_activate', 'com.google.Chrome', 'YouTube', 2, 1),
                  (3, ?, 'app_activate', 'com.google.Chrome', 'YouTube', 3, 1)
                """, arguments: [now - 35 * day, now - day, now - 40 * day])
            let pinned = PeriodCalendar().day(now - 40 * day)
            try ConsolidationStore.pin(.period, key: RetentionPin.periodKey(from: pinned, to: pinned), at: 0, conn)
        }
        let consolidator = Consolidator(db: db, llm: nil, clock: { now })
        func remaining() async throws -> [Int64] {
            try await db.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM text_snapshots ORDER BY id") }
        }

        _ = await consolidator.run(prune: true)
        let beforeConsent = try await remaining()
        XCTAssertEqual(beforeConsent, [1, 2, 3])

        try await db.writer.write { conn in
            try ConsolidationStore.set(ConsolidationStore.Key.firstPruneConsentedAt, String(now), conn)
            var policy = RetentionPolicy.standard
            policy.apply(.keepRaw)
            try policy.save(conn)
        }
        _ = await consolidator.run(prune: true)
        let withKeepRaw = try await remaining()
        XCTAssertEqual(withKeepRaw, [1, 2, 3])

        try await db.writer.write { try RetentionPolicy.standard.save($0) }
        _ = await consolidator.run(prune: true)
        let afterRetention = try await remaining()
        XCTAssertEqual(afterRetention, [2, 3], "보관 기간 안이거나 보존 지정한 기록은 남긴다")
    }
}
