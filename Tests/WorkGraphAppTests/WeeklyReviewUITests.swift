import AppKit
import GRDB
import SwiftUI
import UserNotifications
import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 하루 한 번 정리 제안: 업무 목록 위 한 줄 → 시트에서 고르고 [반영]
@MainActor
final class WeeklyReviewUITests: XCTestCase {
    private func database() throws -> WGDatabase {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let sillog = try tx.upsertNode(label: NodeLabel.task, key: "t_sillog", subtype: nil, title: "Sillog 앱 기능·UI 고도화", props: [:], at: 0)
            let wg = try tx.upsertNode(label: NodeLabel.task, key: "t_wg", subtype: nil, title: "WorkGraph 파이프라인 커밋·PR", props: [:], at: 0)
            for (index, task) in [sillog, wg].enumerated() {
                let session = try tx.upsertNode(label: NodeLabel.session, key: "s\(index)", subtype: nil, title: "세션", props: ["start": .number(0), "end": .number(10), "active_seconds": .number(600)], at: 0)
                _ = try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: 0)
            }
            _ = try tx.upsertNode(label: NodeLabel.topic, key: "그래프 시각화", subtype: nil, title: "그래프 시각화", props: [:], at: 0)
            let item = try tx.upsertNode(label: NodeLabel.laterItem, key: "later:1", subtype: nil, title: "과제 4 제출", props: ["done": .bool(false)], at: 0)
            _ = try tx.upsertEdge(src: item, dst: sillog, type: EdgeType.forTask, props: [:], addWeight: 0, at: 0)
        }
        try ReviewStore(db).replacePending(with: [
            ReviewProposal(kind: .mergeTasks, summary: "Sillog 앱 기능·UI 고도화 ← WorkGraph 파이프라인 커밋·PR", payload: .init(keep: "t_sillog", merge: ["t_wg"])),
            ReviewProposal(kind: .laterDone, summary: "과제 4 제출", payload: .init(key: "later:1")),
        ], now: 0)
        return db
    }

    private nonisolated func count(_ db: WGDatabase, _ sql: String) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    func testApplyingTheChosenProposalsAndSettingTheRestAside() async throws {
        let db = try database()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        state.loadReview()
        XCTAssertEqual(state.reviewProposals.map(\.kind), [.mergeTasks, .laterDone])
        let merge = try XCTUnwrap(state.reviewProposals.first?.id)
        await state.applyReview(selected: [merge], shown: Set(state.reviewProposals.compactMap(\.id)))
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM nodes WHERE label = 'Task'"), 1, "고른 업무 합치기만 반영")
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM nodes WHERE label = 'LaterItem' AND json_extract(props, '$.done') = 1"), 0, "안 고른 것은 반영하지 않는다")
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM review_proposals WHERE status = 'dismissed'"), 1, "안 고른 것은 다시 묻지 않는다")
        XCTAssertTrue(state.reviewProposals.isEmpty)
        XCTAssertFalse(state.reviewSheetOpen)
    }

    /// '더 보기'에 접혀 안 본 제안은 접어 두지 않고 다음에 다시 보여 준다
    func testProposalsTheUserDidNotSeeStayPending() async throws {
        let db = try database()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        state.loadReview()
        let merge = try XCTUnwrap(state.reviewProposals.first?.id)
        await state.applyReview(selected: [merge], shown: [merge])
        XCTAssertEqual(state.reviewProposals.map(\.kind), [.laterDone])
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM review_proposals WHERE status = 'dismissed'"), 0)
    }

    /// 만들기에 실패하면 하루 동안 다시 부르지 않는다 (자리를 비운 10분마다 AI 를 부르지 않게)
    func testWaitsADayAfterAFailedRun() {
        let now = 1_793_923_200.0
        XCTAssertTrue(AppState.reviewDue(day: "2026-11-06", done: "2026-11-05", failedAt: nil, now: now))
        XCTAssertFalse(AppState.reviewDue(day: "2026-11-06", done: "2026-11-06", failedAt: nil, now: now))
        XCTAssertFalse(AppState.reviewDue(day: "2026-11-06", done: "2026-11-05", failedAt: now - 3_600, now: now))
        XCTAssertTrue(AppState.reviewDue(day: "2026-11-06", done: "2026-11-05", failedAt: now - 25 * 3_600, now: now))
    }

    func testTheTaskListShowsALineWhenThereAreProposals() throws {
        let state = AppState(preview: { s in s.phase = .ready; s.taskList = [] }, database: try database())
        state.loadReview()
        let host = NSHostingView(rootView: AnyView(TasksPanel().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let text = OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
        XCTAssertTrue(text.contains("정리제안2개"), text)
    }

    func testTheSheetGroupsProposalsByKind() throws {
        let state = AppState(preview: { $0.phase = .ready }, database: try database())
        state.loadReview()
        let host = NSHostingView(rootView: AnyView(ReviewSheet().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let text = OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
        for word in ["업무합치기", "끝난할일", "과제4제출", "반영"] { XCTAssertTrue(text.contains(word), "\(word): \(text)") }
    }

    func testRunsOncePerDay() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let friday = 1_793_923_200.0                                    // 2026-11-06 (금) 09:00
        XCTAssertEqual(AppState.reviewDay(friday, calendar: calendar), "2026-11-06")
        XCTAssertEqual(AppState.reviewDay(friday + 14 * 3_600 + 3_599, calendar: calendar), "2026-11-06", "그날 23:59 까지 같은 날")
        XCTAssertEqual(AppState.reviewDay(friday + 15 * 3_600, calendar: calendar), "2026-11-07", "자정부터 다음 날")
    }

    func testReviewNotificationOpensTheSheet() {
        XCTAssertEqual(SuggestionNotifier.route(userInfo: ["review": true], action: UNNotificationDefaultActionIdentifier), .review)
    }
}
