import XCTest
@testable import SillogCore

/// Replies in call order to whatever question id it is asked.
final class OrderedJudge: JevChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<JevChoice, JevError>]
    private(set) var optionCounts: [Int] = []
    let modelName = "stub-judge"

    init(_ replies: [Result<JevChoice, JevError>]) { self.replies = replies }

    func choose(state: String, questions: [String: JevQuestion]) async throws -> [String: JevChoice] {
        let (id, question) = questions.first!
        let next = lock.withLock {
            optionCounts.append(question.options.count)
            return replies.isEmpty ? .failure(.badResponse) : replies.removeFirst()
        }
        return [id: try next.get()]
    }
}

final class SeparatedJudgmentTests: XCTestCase {
    private let tasks = (1...20).map { TaskDigest(id: "t_\($0)", title: "업무 \($0)", taskType: nil, topics: [], recentResources: [], lastActive: 0, goal: "목표 \($0)") }

    private func pick(_ choice: String, _ confidence: Double = 0.9) -> Result<JevChoice, JevError> {
        .success(JevChoice(choice: choice, confidence: confidence, probabilities: [choice: confidence]))
    }

    private func input(_ count: Int) -> JudgeInput {
        JudgeInput(rows: Array(Fixtures.frontendRows().prefix(count)), openTasks: tasks, now: 1_000_000)
    }

    func testNewInAnEarlierChunkAsksTheNextChunk() async throws {
        let judge = OrderedJudge([pick("new"), pick("t_18"), pick("off"), pick("new"), pick("new")])
        let state = try await StagedPipeline.decideSeparately(input(3), using: .jev(judge))

        XCTAssertEqual(judge.optionCounts, [20, 6, 20, 20, 6], "17 tasks + 3 specials, then the remaining 3 tasks + 3 specials")
        XCTAssertEqual(state.assignment.rows[1]?.task, "t_18")
        XCTAssertEqual(state.verdicts[2]?.kind, .off)
        XCTAssertEqual(state.verdicts[3]?.kind, .work)
        XCTAssertNil(state.assignment.rows[3], "new work is named later by the organizer")
        XCTAssertEqual(state.input.rows.map(\.row), [1, 2, 3])
        XCTAssertEqual(state.calls.last?.stage, "assign-jev")
    }

    func testFailureOnEveryRowThrowsIncomplete() async {
        let judge = OrderedJudge([.failure(.http(500, "down"))])
        do {
            _ = try await StagedPipeline.decideSeparately(input(2), using: .jev(judge))
            XCTFail("expected incomplete")
        } catch PipelineError.incomplete(_, let missing, _) {
            XCTAssertEqual(missing, [1, 2])
            XCTAssertEqual(judge.optionCounts.count, 1, "stops after the first failure")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
