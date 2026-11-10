import XCTest
@testable import WorkGraphCore

/// 가짜 판단 모델: 부른 차례대로 준비한 답을 돌려준다. 네트워크 없음
final class StubJudge: JevChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<JevChoice, JevError>]
    private(set) var states: [String] = []
    let modelName = "stub-jev"

    init(_ replies: [Result<JevChoice, JevError>]) { self.replies = replies }

    func choose(state: String, questions: [String: JevQuestion]) async throws -> [String: JevChoice] {
        let next: Result<JevChoice, JevError> = lock.withLock {
            states.append(state)
            return replies.isEmpty ? .failure(.badResponse) : replies.removeFirst()
        }
        let choice = try next.get()
        return ["task": choice]
    }
}

final class JevAssignTests: XCTestCase {
    private let tasks = [TaskDigest(id: "t_a", title: "대시보드 카드 UI 구현", taskType: "코드작성", topics: [], recentResources: [], lastActive: 0, goal: "카드 UI 를 만든다")]

    private func reply(_ choice: String, _ confidence: Double) -> Result<JevChoice, JevError> {
        .success(JevChoice(choice: choice, confidence: confidence, probabilities: [choice: confidence]))
    }

    /// 행 workRows 가 업무 행인 ② 직전 상태
    private func state(workRows: ClosedRange<Int>, judge: StubJudge?) -> JudgeState {
        var state = JudgeState(input: JudgeInput(rows: Fixtures.frontendRows(), openTasks: tasks, now: 1_000_000, judge: judge))
        for number in workRows { state.verdicts[number] = RowVerdict(kind: .work, reason: "구현") }
        return state
    }

    func testChoiceRules() {
        func answer(_ choice: String, _ confidence: Double) -> JevChoice { JevChoice(choice: choice, confidence: confidence, probabilities: [choice: confidence]) }
        let ids = ["t_a", "t_b"]
        XCTAssertEqual(JevAssign.resolve(answer("t_a", 0.9), candidates: ids, truncated: false), JevDecision(pick: .task("t_a"), confidence: 0.9))
        XCTAssertEqual(JevAssign.resolve(answer("t_b", JevAssign.confidenceFloor), candidates: ids, truncated: false)?.pick, .task("t_b"), "기준과 같으면 쓴다")
        XCTAssertNil(JevAssign.resolve(answer("t_a", 0.59), candidates: ids, truncated: false), "기준 미만은 LLM 이 판정")
        XCTAssertEqual(JevAssign.resolve(answer("new", 0.8), candidates: ids, truncated: false)?.pick, .new)
        XCTAssertNil(JevAssign.resolve(answer("new", 0.8), candidates: ids, truncated: true), "보기에 못 넣은 업무가 있으면 새 업무 답을 믿지 않는다")
        XCTAssertNil(JevAssign.resolve(answer("t_x", 0.99), candidates: ids, truncated: false), "보기에 없는 답")
        XCTAssertNil(JevAssign.resolve(nil, candidates: ids, truncated: false), "답이 빠짐")

        let many = (1...25).map { TaskDigest(id: "t_\($0)", title: "업무 \($0)", taskType: nil, topics: [], recentResources: [], lastActive: 0, goal: "목표 \($0)") }
        let (question, candidates, truncated) = JevAssign.makeQuestion(many)
        XCTAssertEqual(question.options.count, JevAssign.maxOptions, "새 업무까지 20개")
        XCTAssertEqual(candidates.first, "t_1", "가장 최근 업무부터")
        XCTAssertTrue(truncated)
        XCTAssertEqual(question.options["t_1"], "업무 1: 목표 1")
        XCTAssertNotNil(question.options[JevAssign.newOption])
        XCTAssertFalse(JevAssign.makeQuestion(Array(many.prefix(3))).truncated)

        var big = Fixtures.frontendRows()[0]
        big.snippet = String(repeating: "가", count: 30_000)
        XCTAssertEqual(JevAssign.stateText(big, cards: [:], now: 1_000_000, timeZone: .current).count, JevAssign.stateLimit, "글은 약 2만 자에서 자른다")
    }

    func testConfidentRowsSkipTheLLMNewRowsGetNoCandidatesAndTheRestFallBack() async throws {
        // 행 1, 2 = 기존 업무 (확신 높음), 3 = 새 업무, 4 = 확신 낮음
        let judge = StubJudge([reply("t_a", 0.9), reply("t_a", 0.95), reply("new", 0.8), reply("t_a", 0.4)])
        let llm = StubLLM([.success(#"{"tasks":[{"ref":"A","match":"new","title":"디자인 시안 정리","goal":"시안을 정리한다"}],"rows":[{"rows":"3","task":"A","reason":"시안"}]}"#),
                           .success(#"{"tasks":[],"rows":[{"rows":"4","task":"t_a","reason":"카드 구현"}]}"#)])
        let next = try await StagedPipeline.assign(state(workRows: 1...4, judge: judge), llm)

        XCTAssertEqual(judge.states.count, 4, "행마다 요청 하나")
        XCTAssertTrue(judge.states[0].contains("TaskCard.tsx"))
        XCTAssertFalse(judge.states[0].contains("localhost:3000"), "글은 그 행 하나")
        XCTAssertEqual(llm.calls, 2, "확정된 행은 LLM 에 묻지 않는다")
        XCTAssertTrue(llm.users[0].contains("OPEN_TASKS:\n(none)"), "새 업무로 본 행은 후보 없이 물어 새 업무를 정의하게 한다")
        XCTAssertTrue(llm.users[0].contains("localhost:3000"))
        XCTAssertFalse(llm.users[0].contains("TaskCard.tsx"))
        XCTAssertTrue(llm.users[1].contains("- id=t_a |"), "확신이 낮은 행은 지금처럼 후보 전체")
        XCTAssertTrue(llm.users[1].contains("npm run dev"))
        XCTAssertFalse(llm.users[1].contains("localhost:3000"))

        XCTAssertEqual(next.assignment.rows[1]?.task, "t_a")
        XCTAssertTrue(next.assignment.rows[2]?.reason.contains("판단 모델(Jev)") ?? false, "판단 모델이 고른 행은 이유에 표시")
        XCTAssertEqual(next.assignment.rows[3]?.task, "j-A")
        XCTAssertEqual(next.assignment.rows[4]?.task, "t_a")
        XCTAssertFalse(next.assignment.rows[4]?.reason.contains("판단 모델") ?? true, "LLM 이 판정한 행")
        XCTAssertEqual(next.assignment.tasks.map(\.ref), ["t_a", "j-A"])
        XCTAssertEqual(next.calls.map(\.stage), ["assign-jev", "assign", "assign"])
        XCTAssertEqual(next.assignAttempts, 1)
        XCTAssertTrue(next.unassigned.isEmpty)

        // 앱이 받아들이는 판정인지: 기존 업무 id 와 새 업무 ref 가 모두 풀린다
        let patch = StagedPipeline.patch(from: next)
        XCTAssertNil(AssignmentCheck.rejection(patch, rows: Array(Fixtures.frontendRows().prefix(4)), openTasks: tasks, now: 2_000_000))
    }

    func testAJevFailureStopsAskingAndTheLLMDecidesEveryRow() async throws {
        let judge = StubJudge([.failure(.http(429, "slow down"))])
        let llm = StubLLM([.success(#"{"tasks":[],"rows":[{"rows":"1-3","task":"t_a","reason":"카드 구현"}]}"#)])
        let next = try await StagedPipeline.assign(state(workRows: 1...3, judge: judge), llm)

        XCTAssertEqual(judge.states.count, 1, "첫 오류에서 멈춘다")
        XCTAssertEqual(llm.calls, 1)
        XCTAssertTrue(llm.users[0].contains("- id=t_a |"), "LLM 은 지금처럼 후보 전체를 본다")
        XCTAssertTrue(llm.users[0].contains("localhost:3000"), "행 3개 모두")
        XCTAssertEqual(next.assignment.rows.count, 3)
        XCTAssertEqual(next.calls.map(\.stage), ["assign-jev", "assign"])
        XCTAssertFalse(next.assignment.rows.values.contains { $0.reason.contains("판단 모델") })
    }

    func testWithoutAJudgeTheLLMDecidesAsBefore() async throws {
        let llm = StubLLM([.success(#"{"tasks":[],"rows":[{"rows":"1-2","task":"t_a","reason":"카드 구현"}]}"#)])
        let next = try await StagedPipeline.assign(state(workRows: 1...2, judge: nil), llm)
        XCTAssertEqual(llm.calls, 1)
        XCTAssertEqual(next.calls.map(\.stage), ["assign"])
        XCTAssertEqual(next.assignment.rows[1]?.task, "t_a")
    }
}
