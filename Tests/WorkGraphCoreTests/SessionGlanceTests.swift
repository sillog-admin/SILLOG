import XCTest
import GRDB
@testable import WorkGraphCore

/// 매우 짧은 세션 붙이기: 1분 미만 훑어본 행은 새 세션 대신 같은 날 같은 업무의 세션에 붙인다 (11/06: 세션 654개 중 387개가 1분 미만).
/// 업무 판정은 그대로이고, 보여 주는 단위만 합친다
final class SessionGlanceTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = seoul; return c }

    private func time(_ text: String) -> Double {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = seoul; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!.timeIntervalSince1970
    }

    private func row(_ n: Int, _ start: String, dwell: Int, chat: Bool = false) -> ActivityRow {
        let s = time(start)
        return ActivityRow(row: n, start: s, end: s + Double(max(dwell, 1)), dwell: dwell, app: chat ? "Claude Code" : "Discord", appBundle: chat ? "claude-code" : "com.hnc.Discord",
                           title: "#일반-채팅", uri: nil, type: chat ? "AIChat" : nil, projectKey: nil, projectTitle: nil, snippet: nil,
                           observationIds: chat ? [] : [Int64(n)], isChat: chat)
    }

    private func sessions(_ tx: GraphTx) throws -> [(start: Double, end: Double)] {
        try tx.nodes(label: NodeLabel.session).map { ($0.props["start"]?.doubleValue ?? 0, $0.props["end"]?.doubleValue ?? 0) }.sorted { $0.start < $1.start }
    }

    private func apply(_ rows: [ActivityRow], task: Int64, tx: GraphTx) throws -> SessionBuilder.Stats {
        var stats = SessionBuilder.Stats()
        try SessionBuilder(calendar: calendar).apply(rows.map { RowAssignment(row: $0, taskId: task) }, summaries: [:], tx: tx, stats: &stats)
        return stats
    }

    func testGlancesJoinTheSameDaySessionInsteadOfStartingOne() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_team", subtype: nil, title: "팀 Discord 소통", props: [:], at: 0)
            XCTAssertEqual(try apply([row(1, "2026-11-03 10:00", dwell: 600)], task: task, tx: tx).sessions, 1)

            let glance = try apply([row(2, "2026-11-03 13:00", dwell: 8)], task: task, tx: tx)
            XCTAssertEqual(glance.sessions, 0, "3시간 뒤 8초 훑어본 것은 새 세션이 아니다")
            XCTAssertEqual(glance.sessionsExtended, 1)
            let session = try XCTUnwrap(tx.nodes(label: NodeLabel.session).first)
            XCTAssertEqual(session.props["active_seconds"], .number(608), "활동 시간은 실제만큼만")
            XCTAssertEqual(session.props["end"], .number(time("2026-11-03 13:00") + 8))

            XCTAssertEqual(try apply([row(3, "2026-11-04 09:00", dwell: 8)], task: task, tx: tx).sessions, 1, "다른 날이면 새 세션")
            XCTAssertEqual(try apply([row(4, "2026-11-03 16:00", dwell: 300)], task: task, tx: tx).sessions, 1, "1분 넘게 한 일은 지금처럼 30분이 넘게 비면 새 세션")
            XCTAssertEqual(try tx.nodes(label: NodeLabel.session).count, 3)
        }
    }

    /// 붙인 훑어보기가 그 세션을 늘려도, 뒤따르는 진짜 작업은 30분 규칙대로 새 세션이다 (같은 정리에서도, 다음 정리에서도)
    func testAGlanceDoesNotPullLaterWorkIntoAnOldSession() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_app", subtype: nil, title: "앱 개발", props: [:], at: 0)
            _ = try apply([row(1, "2026-11-03 10:00", dwell: 3_600)], task: task, tx: tx)                                   // 10:00–11:00
            _ = try apply([row(2, "2026-11-03 13:00", dwell: 8), row(3, "2026-11-03 13:01", dwell: 1_200)], task: task, tx: tx)   // 훑어보고 바로 20분 작업
            var spans = try sessions(tx)
            XCTAssertEqual(spans.count, 2, "13:00 훑어보기와 13:01 작업은 새 세션 하나")
            XCTAssertEqual(spans[1].start, time("2026-11-03 13:00"), "바로 이어 일한 훑어보기는 그 작업 세션에")
            XCTAssertEqual(spans[0].end, time("2026-11-03 10:00") + 3_600, "옛 세션은 늘어나지 않는다")

            _ = try apply([row(4, "2026-11-03 15:00", dwell: 8)], task: task, tx: tx)                                       // 혼자 훑어보기: 붙는다
            _ = try apply([row(5, "2026-11-03 15:40", dwell: 600)], task: task, tx: tx)                                     // 다음 정리의 진짜 작업
            spans = try sessions(tx)
            XCTAssertEqual(spans.count, 3, "훑어보기가 늘린 끝이 아니라 실제 작업이 끝난 때부터 30분을 잰다")
        }
    }

    /// AI 에게 한 말(활동 0초)은 그 뒤 작업의 시작이라 훑어보기로 보지 않는다
    func testChatRowsStartWorkInsteadOfGlancing() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_app", subtype: nil, title: "앱 개발", props: [:], at: 0)
            _ = try apply([row(1, "2026-11-03 10:00", dwell: 3_600)], task: task, tx: tx)
            _ = try apply([row(2, "2026-11-03 13:00", dwell: 0, chat: true), row(3, "2026-11-03 13:02", dwell: 1_200)], task: task, tx: tx)
            let spans = try sessions(tx)
            XCTAssertEqual(spans.count, 2)
            XCTAssertEqual(spans[1].start, time("2026-11-03 13:00"))
        }
    }
}
