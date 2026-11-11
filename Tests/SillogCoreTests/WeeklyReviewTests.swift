import XCTest
import GRDB
@testable import SillogCore

/// 하루 한 번 정리 제안: 전체 기간을 다시 보고 합칠 업무·주제·문제, 끝낼·지울 나중에 할 일, 붙일 짧은 세션을 제안한다. 반영은 사용자가 고른 것만
final class WeeklyReviewTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = seoul; return c }

    private func time(_ text: String) -> Double {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = seoul; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!.timeIntervalSince1970
    }

    private struct Fixture {
        var sillog: Int64 = 0, wg: Int64 = 0, rec: Int64 = 0, ml: Int64 = 0
        var s1: Int64 = 0, s2: Int64 = 0, s3: Int64 = 0, s5: Int64 = 0
        var graph: Int64 = 0, graph3d: Int64 = 0, swiftui: Int64 = 0
        var lateDeadline: Int64 = 0, request: Int64 = 0, report: Int64 = 0
        var p1: Int64 = 0, p2: Int64 = 0
    }

    private func seed(_ db: SillogDatabase) throws -> Fixture {
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let at = self.time("2026-11-03 09:00")
            func node(_ label: String, _ key: String, _ title: String, _ props: [String: JSONValue] = [:]) throws -> Int64 {
                try tx.upsertNode(label: label, key: key, subtype: label == NodeLabel.problem ? "build" : nil, title: title, props: props, at: at)
            }
            func edge(_ src: Int64, _ dst: Int64, _ type: String, _ weight: Double = 1) throws {
                _ = try tx.upsertEdge(src: src, dst: dst, type: type, props: [:], addWeight: weight, at: at)
            }
            var f = Fixture()
            let folder: JSONValue = .object(["file:~/Desktop/study/앱 개발/Sillog": .number(300)])
            f.sillog = try node(NodeLabel.task, "t_sillog", "Sillog 앱 기능·UI 고도화", ["active_seconds": .number(3008), "last_active": .number(at), "project_seconds": folder])
            f.wg = try node(NodeLabel.task, "t_wg", "Sillog 파이프라인 커밋·PR", ["active_seconds": .number(600), "last_active": .number(at), "project_seconds": folder])
            f.rec = try node(NodeLabel.task, "t_rec", "개인 음성 기록 앱 녹음 설계", ["active_seconds": .number(900), "last_active": .number(at)])
            f.ml = try node(NodeLabel.task, "t_ml", "기계학습기초 과제", ["active_seconds": .number(5), "last_active": .number(at)])
            func session(_ key: String, _ task: Int64, _ start: String, _ end: String, _ active: Double, _ summary: String) throws -> Int64 {
                let id = try node(NodeLabel.session, key, "\(start) 세션", ["start": .number(self.time(start)), "end": .number(self.time(end)), "active_seconds": .number(active),
                                                                         "summary": .string(summary), "summaries": .array([.string(summary)])])
                try edge(id, task, EdgeType.partOf)
                return id
            }
            f.s1 = try session("s1", f.sillog, "2026-11-03 10:00", "2026-11-03 11:00", 3000, "채팅 화면을 고쳤다.")
            f.s2 = try session("s2", f.sillog, "2026-11-03 13:00", "2026-11-03 13:00", 8, "Discord 채널을 확인했다.")
            f.s3 = try session("s3", f.wg, "2026-11-03 15:00", "2026-11-03 15:30", 600, "PR 을 올렸다.")
            _ = try session("s4", f.rec, "2026-11-02 15:00", "2026-11-02 15:30", 900, "녹음 버튼을 만들었다.")
            f.s5 = try session("s5", f.ml, "2026-11-01 09:00", "2026-11-01 09:00", 5, "과제 공지를 봤다.")
            let chrome = try node(NodeLabel.app, "com.google.Chrome", "Google Chrome")
            try edge(f.s2, chrome, EdgeType.used, 8)
            try edge(f.s1, chrome, EdgeType.used, 100)
            try edge(f.s1, f.s2, EdgeType.switchedTo)
            try edge(f.s2, f.s3, EdgeType.switchedTo)
            f.graph = try node(NodeLabel.topic, "그래프 시각화", "그래프 시각화")
            f.graph3d = try node(NodeLabel.topic, "3D 그래프 시각화", "3D 그래프 시각화")
            f.swiftui = try node(NodeLabel.topic, "SwiftUI", "SwiftUI")
            try edge(f.sillog, f.graph, EdgeType.about)
            try edge(f.sillog, f.graph3d, EdgeType.about)
            try edge(f.wg, f.graph3d, EdgeType.about)
            try edge(f.sillog, f.swiftui, EdgeType.about)
            f.lateDeadline = try node(NodeLabel.laterItem, "later:1", "자료구조 실습과제 4를 10월 27일까지 제출", ["done": .bool(false), "at": .number(self.time("2026-10-20 09:00"))])
            f.request = try node(NodeLabel.laterItem, "later:2", "직장업무 데이터를 삭제해 달라는 요청이 있었음", ["done": .bool(false), "at": .number(at)])
            f.report = try node(NodeLabel.laterItem, "later:3", "보고서 3장 고치기", ["done": .bool(false), "at": .number(at)])
            for item in [f.lateDeadline, f.request, f.report] { try edge(item, item == f.lateDeadline ? f.ml : f.sillog, EdgeType.forTask) }
            f.p1 = try node(NodeLabel.problem, "problem:build:1", "TaskEraseTests 에서 async 호출이 autoclosure 안에 있어 컴파일 오류")
            f.p2 = try node(NodeLabel.problem, "problem:build:2", "TaskEraseTests.swift async 호출을 동기 autoclosure 에 써서 빌드 실패")
            try edge(f.s1, f.p1, EdgeType.hit)
            try edge(f.s3, f.p2, EdgeType.hit)
            return f
        }
    }

    private func replies(_ f: Fixture) -> [Result<String, LLMError>] {
        [.success(#"{"groups":[{"keep":"t_sillog","merge":["t_wg","t_rec"],"title":"Sillog 앱 기능·UI 고도화"}],"not_goals":[]}"#),   // 제목을 그대로 돌려줘도 '→' 를 붙이지 않는다
         .success("""
            {"topic_groups":[{"keep":"T\(f.graph)","merge":["T\(f.graph3d)"]}],
             "later":[{"id":"L\(f.lateDeadline)","action":"done"},{"id":"L\(f.request)","action":"drop"}],
             "problem_groups":[{"keep":"P\(f.p1)","merge":["P\(f.p2)"]}]}
            """)]
    }

    private func plan(_ db: SillogDatabase, _ llm: StubLLM) async throws -> [ReviewProposal] {
        try await WeeklyReview.plan(db: db, llm: llm, now: time("2026-11-06 09:00"), calendar: calendar)
    }

    func testPlansMergesTidyingAndShortSessions() async throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let llm = StubLLM(replies(f))
        let proposals = try await plan(db, llm)
        XCTAssertEqual(proposals.map(\.kind), [.mergeTasks, .mergeTopics, .laterDone, .laterDrop, .mergeProblems, .joinSessions])
        XCTAssertEqual(proposals[0].summary, "Sillog 앱 기능·UI 고도화 ← Sillog 파이프라인 커밋·PR, 개인 음성 기록 앱 녹음 설계")
        XCTAssertEqual(proposals[1].summary, "그래프 시각화 ← 3D 그래프 시각화")
        XCTAssertEqual(proposals[2].summary, "자료구조 실습과제 4를 10월 27일까지 제출")
        XCTAssertEqual(proposals[5].summary, "1분 미만 세션 1개를 같은 날 세션에 붙이기", "s5 는 그날 다른 세션이 없어 그대로")
        XCTAssertTrue(llm.systems[0].contains("code name"), "업무 합치기는 보강한 규칙으로")
        XCTAssertTrue(llm.users[0].contains("folders: Sillog"), "같은 프로젝트 폴더에서 일한 업무는 그 근거를 보여 준다: \(llm.users[0])")
        XCTAssertTrue(llm.users[1].contains("T\(f.graph3d) | 3D 그래프 시각화 | 2"), llm.users[1])
        XCTAssertTrue(llm.users[1].contains("NOW: 2026-11-06"))
    }

    func testApplyingMergesAndTidiesTheGraph() async throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let proposals = try await plan(db, StubLLM(replies(f)))
        let applied = try await db.writer.write { try WeeklyReview.apply(proposals, conn: $0, now: self.time("2026-11-06 09:05")) }
        XCTAssertEqual(applied, Array(repeating: true, count: proposals.count))
        try await db.writer.read { conn in
            let tx = GraphTx(conn)
            XCTAssertEqual(try tx.nodes(label: NodeLabel.task).map(\.key).sorted(), ["t_ml", "t_sillog"])
            XCTAssertNil(try tx.node(id: f.graph3d))
            XCTAssertEqual(Set(try tx.edges(to: f.graph, type: EdgeType.about).map(\.src)), [f.sillog], "주제를 쓰던 업무가 남는 주제로")
            XCTAssertEqual(try tx.node(id: f.lateDeadline)?.props["done"], .bool(true))
            XCTAssertNil(try tx.node(id: f.request))
            XCTAssertNotNil(try tx.node(id: f.report))
            XCTAssertNil(try tx.node(id: f.p2))
            XCTAssertEqual(Set(try tx.edges(to: f.p1, type: EdgeType.hit).map(\.src)), [f.s1, f.s3])
            XCTAssertNil(try tx.node(id: f.s2), "짧은 세션은 붙고 사라진다")
            let s1 = try XCTUnwrap(tx.node(id: f.s1))
            XCTAssertEqual(s1.props["active_seconds"], .number(3008))
            XCTAssertEqual(s1.props["end"], .number(self.time("2026-11-03 13:00")))
            XCTAssertEqual(s1.props["summaries"]?.arrayValue?.compactMap(\.stringValue), ["채팅 화면을 고쳤다.", "Discord 채널을 확인했다."])
            XCTAssertEqual(try tx.edges(from: f.s1, type: EdgeType.used).first?.weight, 108)
            XCTAssertEqual(try tx.edges(from: f.s1, type: EdgeType.switchedTo).map(\.dst), [f.s3], "흐름은 붙인 세션으로 이어진다")
            XCTAssertNotNil(try tx.node(id: f.s5))
        }
    }

    func testStoreKeepsPendingAndDoesNotAskAgainWhatWasDismissed() async throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let store = ReviewStore(db)
        let first = try await plan(db, StubLLM(replies(f)))
        try store.replacePending(with: first, now: 1)
        let pending = try store.pending()
        XCTAssertEqual(pending.count, first.count)
        let topic = try XCTUnwrap(pending.first { $0.kind == .mergeTopics })
        try store.decide(applied: pending.filter { $0.kind == .laterDone }.compactMap(\.id), dismissed: [try XCTUnwrap(topic.id)], now: 2)
        XCTAssertEqual(try store.pending().count, first.count - 2)
        try store.replacePending(with: try await plan(db, StubLLM(replies(f))), now: 3)
        XCTAssertFalse(try store.pending().contains { $0.kind == .mergeTopics }, "거절한 제안은 다음에 다시 묻지 않는다")
        XCTAssertTrue(try store.pending().contains { $0.kind == .laterDone }, "반영한 것이 또 나오면 다시 묻는다 (같은 일이 다시 생긴 것)")
        XCTAssertTrue(try store.pending().contains { $0.kind == .mergeTasks })
    }

    /// 거절한 짝은 다음에 묶음이 달라져도 다시 묻지 않는다. 남은 짝만 남기고 줄 글도 새로 쓴다
    func testDismissedPairsStayOutWhenGroupsChange() throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let store = ReviewStore(db)
        let topics = ["그래프 시각화": "그래프 시각화", "3D 그래프 시각화": "3D 그래프 시각화", "SwiftUI": "SwiftUI"]
        let tasks = ["t_sillog": "Sillog 앱 기능·UI 고도화", "t_wg": "Sillog 파이프라인 커밋·PR"]
        try store.replacePending(with: [
            .make(.mergeTopics, .init(keep: "그래프 시각화", merge: ["3D 그래프 시각화"], names: topics)),
            .make(.laterDone, .init(key: "later:3", names: ["later:3": "보고서 3장 고치기"])),
            .make(.mergeTasks, .init(keep: "t_sillog", merge: ["t_wg"], names: tasks)),
            .make(.joinSessions, .init(moves: [["s2", "s1"]])),
        ], now: 1)
        try store.decide(applied: [], dismissed: try store.pending().compactMap(\.id), now: 2)
        try store.replacePending(with: [
            .make(.mergeTopics, .init(keep: "3D 그래프 시각화", merge: ["그래프 시각화", "SwiftUI"], names: topics)),
            .make(.laterDone, .init(key: "later:3", names: ["later:3": "보고서 3장 고치기"])),
            .make(.mergeTasks, .init(keep: "t_wg", merge: ["t_sillog"], title: "Sillog", names: tasks)),
            .make(.joinSessions, .init(moves: [["s2", "s1"], ["s5", "s4"]])),
        ], now: 3)
        XCTAssertEqual(try store.pending().map(\.summary), ["3D 그래프 시각화 ← SwiftUI", "Sillog 파이프라인 커밋·PR → Sillog", "1분 미만 세션 1개를 같은 날 세션에 붙이기"])
        XCTAssertEqual(try store.pending().last?.payload.moves, [["s5", "s4"]])
    }

    /// 매일 만들므로 알림은 새로 생긴 제안이 있을 때만: 갈아 끼울 때 어제 대기 중이던 것에 없던 제안 수를 돌려준다
    func testCountsOnlyProposalsThatWereNotPendingBefore() throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let store = ReviewStore(db)
        let topics = ["그래프 시각화": "그래프 시각화", "3D 그래프 시각화": "3D 그래프 시각화", "SwiftUI": "SwiftUI"]
        let yesterday: [ReviewProposal] = [.make(.mergeTopics, .init(keep: "그래프 시각화", merge: ["3D 그래프 시각화"], names: topics)),
                                           .make(.laterDone, .init(key: "later:1"))]
        XCTAssertEqual(try store.replacePending(with: yesterday, now: 1), 2)
        XCTAssertEqual(try store.replacePending(with: yesterday, now: 2), 0, "어제와 같으면 새 제안 없음")
        let today = yesterday + [.make(.mergeTopics, .init(keep: "그래프 시각화", merge: ["SwiftUI"], names: topics))]
        XCTAssertEqual(try store.replacePending(with: today, now: 3), 1)
        XCTAssertEqual(try store.pending().count, 3)
    }

    /// 하나씩 반영하고 결과를 돌려준다. 앞에서 합쳐져 사라진 노드를 가리키는 제안은 남는 노드로 따라간다
    func testApplyReportsEachProposalAndFollowsEarlierMerges() async throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let results = try await db.writer.write { conn in
            try WeeklyReview.apply([
                .make(.mergeTopics, .init(keep: "그래프 시각화", merge: ["3D 그래프 시각화"])),
                .make(.mergeTopics, .init(keep: "3D 그래프 시각화", merge: ["SwiftUI"])),       // 3D 는 앞에서 합쳐졌다 → 그래프 시각화로
                .make(.laterDone, .init(key: "later:없음")),
            ], conn: conn, now: 1)
        }
        XCTAssertEqual(results, [true, true, false])
        try await db.writer.read { conn in
            XCTAssertNil(try GraphTx(conn).node(id: f.swiftui))
            XCTAssertEqual(Set(try GraphTx(conn).edges(to: f.graph, type: EdgeType.about).map(\.src)), [f.sillog, f.wg])
        }
    }

    /// 반영과 표시를 한 번에: 반영한 것은 applied, 못 한 것은 skipped(다음에 다시 물을 수 있다), 안 고른 것은 dismissed
    func testStoreAppliesAndMarksInOneGo() async throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let store = ReviewStore(db)
        try store.replacePending(with: [
            .make(.laterDone, .init(key: "later:3")),
            .make(.laterDone, .init(key: "later:없음")),
            .make(.laterDrop, .init(key: "later:2")),
        ], now: 1)
        let ids = try store.pending().compactMap(\.id)
        let chosen = try store.pending().filter { $0.kind == .laterDone }
        let applied = try await db.writer.write { try ReviewStore.apply($0, chosen: chosen, dismissed: [ids[2]], now: 2) }
        XCTAssertEqual(applied, 1)
        let statuses = try await db.writer.read { try String.fetchAll($0, sql: "SELECT status FROM review_proposals ORDER BY id") }
        XCTAssertEqual(statuses, ["applied", "skipped", "dismissed"])
    }

    /// 제안을 만든 뒤 짧은 세션이 길어졌거나 다른 업무로 갔으면 붙이지 않는다
    func testJoiningSkipsSessionsThatChanged() async throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        try await db.writer.write { try GraphTx($0).setProps(nodeId: f.s2, ["active_seconds": .number(300)], at: 1) }
        let results = try await db.writer.write { try WeeklyReview.apply([.make(.joinSessions, .init(moves: [["s2", "s1"], ["s5", "s1"]]))], conn: $0, now: 2) }
        XCTAssertEqual(results, [false], "s2 는 이제 짧지 않고, s5 는 다른 업무·다른 날")
        let left = try await db.writer.read { try GraphTx($0).node(id: f.s2) }
        XCTAssertNotNil(left)
    }

    /// 주제·문제 정리 호출이 실패해도 업무 합치기 제안은 남긴다
    func testKeepsTaskMergesWhenTidyingFails() async throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let proposals = try await plan(db, StubLLM([.success(#"{"groups":[{"keep":"t_sillog","merge":["t_wg"]}],"not_goals":[]}"#), .failure(.transport("오프라인"))]))
        XCTAssertEqual(proposals.map(\.kind), [.mergeTasks, .joinSessions])
    }

    /// 목록이 너무 길면 자주 본 주제·최근 할 일·최근 문제만 보낸다
    func testTidyListsAreCapped() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let (prompt, keys, _) = try db.writer.read { try WeeklyReview.tidyPrompt($0, now: self.time("2026-11-06 09:00"), calendar: self.calendar, limits: (topics: 1, later: 1, problems: 1)) }
        XCTAssertTrue(prompt.contains("T\(f.graph3d) |"), "가장 많이 쓴 주제")
        XCTAssertFalse(prompt.contains("T\(f.swiftui) |"))
        XCTAssertTrue(prompt.contains("L\(f.report) |"), "가장 최근 할 일")
        XCTAssertFalse(prompt.contains("L\(f.lateDeadline) |"))
        XCTAssertTrue(prompt.contains("P\(f.p2) |"), "가장 최근 문제")
        XCTAssertEqual(keys.count, 3)
    }

    func testNothingToProposeWithoutAnswers() async throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let proposals = try await plan(db, StubLLM([.success(#"{"groups":[],"not_goals":[]}"#), .success(#"{"topic_groups":[],"later":[],"problem_groups":[]}"#)]))
        XCTAssertEqual(proposals.map(\.kind), [.joinSessions])
    }

    /// 같은 나중에 할 일이 두 업무에 다 걸려 있어도 합치기가 실패하지 않는다 (예전에는 UNIQUE 오류로 반영 전체가 멈췄다)
    func testMergingTasksThatShareALaterItem() async throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        try await db.writer.write { conn in
            _ = try GraphTx(conn).upsertEdge(src: f.report, dst: f.wg, type: EdgeType.forTask, props: [:], addWeight: 0, at: 0)
            _ = try TaskMerger.merge(TaskMerger.Group(keep: "t_sillog", merge: ["t_wg"]), conn: conn, now: 1)
        }
        let links = try await db.writer.read { try GraphTx($0).edges(from: f.report, type: EdgeType.forTask).map(\.dst) }
        XCTAssertEqual(links, [f.sillog])
    }
}
