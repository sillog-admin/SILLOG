import XCTest
@testable import SillogCore

/// Replies per row, matched by a title in the state text, so concurrent calls stay deterministic.
final class RowJudge: ChoiceModel, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: [Result<ChoiceAnswer, ChoiceError>]]
    private(set) var optionCounts: [String: [Int]] = [:]
    private(set) var asked: [ChoiceQuestion] = []
    let modelName = "stub-judge"

    init(_ replies: [String: [Result<ChoiceAnswer, ChoiceError>]]) { self.replies = replies }

    func choose(state: String, questions: [String: ChoiceQuestion]) async throws -> [String: ChoiceAnswer] {
        let (id, question) = questions.first!
        let next: Result<ChoiceAnswer, ChoiceError> = lock.withLock {
            guard let key = replies.keys.sorted().first(where: { state.contains($0) }) else { return .failure(.badResponse) }
            optionCounts[key, default: []].append(question.options.count)
            asked.append(question)
            return replies[key]!.isEmpty ? .failure(.badResponse) : replies[key]!.removeFirst()
        }
        return [id: try next.get()]
    }
}

final class SeparatedJudgmentTests: XCTestCase {
    private let tasks = (1...20).map { TaskDigest(id: "t_\($0)", title: "업무 \($0)", taskType: nil, topics: [], recentResources: [], lastActive: 0, goal: "목표 \($0)") }
    // Titles of Fixtures.frontendRows() rows 1-3.
    private let r1 = "TaskCard.tsx", r2 = "Card - shadcn/ui", r3 = "localhost:3000"

    private func pick(_ choice: String, _ confidence: Double = 0.9) -> Result<ChoiceAnswer, ChoiceError> {
        .success(ChoiceAnswer(choice: choice, confidence: confidence, probabilities: [choice: confidence]))
    }

    private func input(_ count: Int) -> JudgeInput {
        JudgeInput(rows: Array(Fixtures.frontendRows().prefix(count)), openTasks: tasks, now: 1_000_000)
    }

    func testNewInAnEarlierChunkAsksTheNextChunk() async throws {
        let judge = RowJudge([r1: [pick("new"), pick("t_18")], r2: [pick("off")], r3: [pick("new"), pick("new")]])
        let state = try await StagedPipeline.decideSeparately(input(3), using: .choice(judge))

        XCTAssertEqual(judge.optionCounts[r1], [20, 6], "17 tasks + 3 specials, then the remaining 3 tasks + 3 specials")
        XCTAssertEqual(judge.optionCounts[r2], [20])
        XCTAssertEqual(state.assignment.rows[1]?.task, "t_18")
        XCTAssertEqual(state.verdicts[2]?.kind, .off)
        XCTAssertEqual(state.verdicts[3]?.kind, .work)
        XCTAssertNil(state.assignment.rows[3], "new work is named later by the organizer")
        XCTAssertEqual(state.input.rows.map(\.row), [1, 2, 3])
        XCTAssertEqual(state.calls.last?.stage, "assign-choice")
    }

    /// A record that does not show its goal is off, not none; none is left for records with no content.
    func testARecordThatDoesNotShowItsGoalIsOff() async throws {
        let judge = RowJudge([r1: [pick("off")]])
        _ = try await StagedPipeline.decideSeparately(input(1), using: .choice(judge))
        let question = try XCTUnwrap(judge.asked.first)
        XCTAssertTrue(question.instructions.contains("does not show which goal it serves"), question.instructions)
        XCTAssertTrue(question.options["off"]?.contains("does not show which goal it serves") == true, question.options["off"] ?? "")
        XCTAssertFalse(question.options["none"]?.contains("Too little content") == true, question.options["none"] ?? "")
    }

    func testLowConfidenceBecomesNoneInsteadOfStalling() async throws {
        let judge = RowJudge([r1: [pick("t_1", 0.3)]])
        let state = try await StagedPipeline.decideSeparately(input(1), using: .choice(judge))
        XCTAssertEqual(state.verdicts[1]?.kind, RowKind.none)
        XCTAssertEqual(state.input.rows.map(\.row), [1])
    }

    func testOnlyTheLeadingDecidedRowsAreKeptAndTheErrorIsLogged() async throws {
        let judge = RowJudge([r1: [pick("t_1")], r2: [.failure(.http(500, "down"))], r3: [pick("t_2")]])
        let state = try await StagedPipeline.decideSeparately(input(3), using: .choice(judge))
        XCTAssertEqual(state.input.rows.map(\.row), [1], "row 3 waits until row 2 is decided")
        XCTAssertNil(state.assignment.rows[3])
        XCTAssertTrue(state.calls.last?.arguments.contains("down") ?? false, state.calls.last?.arguments ?? "-")
    }

    func testFailureOnTheFirstRowThrowsIncomplete() async {
        let judge = RowJudge([r1: [.failure(.http(500, "down"))], r2: [pick("t_1")]])
        do {
            _ = try await StagedPipeline.decideSeparately(input(2), using: .choice(judge))
            XCTFail("expected incomplete")
        } catch PipelineError.incomplete(_, let missing, _) {
            XCTAssertEqual(missing, [1, 2])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStateTextIsClipped() {
        var row = Fixtures.frontendRows()[0]
        row.snippet = String(repeating: "가", count: 30_000)
        XCTAssertEqual(StagedPipeline.choiceState(row, cards: [:], now: 1_000_000, timeZone: .current).count, StagedPipeline.choiceStateLimit)
    }
}
