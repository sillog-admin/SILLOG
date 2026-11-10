import XCTest
@testable import WorkGraphCore

final class DigestValidatorTests: XCTestCase {
    private func input() -> DigestInput {
        var metrics = DigestMetrics()
        metrics.activeSeconds = 6 * 3600 + 20 * 60
        metrics.sessions = 4
        var input = DigestInput(level: .week, period: "2026-W40", from: "2026-09-28", to: "2026-10-04",
                                task: .init(key: "t_1", title: "중간보고서 작성", goal: nil, status: "active"),
                                time: TimePhrase.approx(metrics.activeSeconds), metrics: metrics)
        input.sessions = [.init(date: "9/28", summaries: ["중간보고서 3장 초안을 작성했다."])]
        input.problems = [.init(key: "problem:build:aa", text: "빌드 오류", state: "resolved", resolvedBy: "Stack Overflow", date: "9/29"),
                          .init(key: "problem:test:bb", text: "테스트 실패", state: "open", resolvedBy: nil, date: "9/30")]
        input.laterItems = [.init(key: "later:cc", text: "표 정리", state: "open", date: "9/30")]
        input.anchors = ["later:cc", "problem:build:aa", "problem:test:bb", "t_1"]
        input.evidence = ["problem:build:aa"]
        return input
    }

    private func content(summary: String = "중간보고서 3장 초안을 쓰고 빌드 오류를 해결했다. 약 6시간 20분 작업했다.",
                         progress: [DigestContent.Item]? = nil, problems: [DigestContent.Item]? = nil) -> DigestContent {
        DigestContent(summary: summary,
                      progress: progress ?? [.init(text: "빌드 오류를 해결했다.", status: "evidenced", anchors: ["problem:build:aa"]),
                                             .init(text: "3장 초안을 썼다.", status: "in_progress", anchors: ["t_1"])],
                      problems: problems ?? [.init(text: "빌드 오류", state: "resolved", anchors: ["problem:build:aa"]),
                                             .init(text: "테스트 실패", state: "open", anchors: ["problem:test:bb"])],
                      openItems: [.init(text: "표 정리", anchors: ["later:cc"])],
                      numbersUsed: [.init(name: "active_seconds", value: 22_800)])
    }

    func testAcceptsGroundedDigest() {
        XCTAssertEqual(DigestValidator.problems(content(), input: input()), [])
    }

    func testRejectsNumbersNotInInputOrMetrics() {
        let issues = DigestValidator.problems(content(summary: "보고서 5개를 끝냈다."), input: input())
        XCTAssertTrue(issues.contains { $0.contains("5") }, "\(issues)")
    }

    func testRejectsAnchorsThatWereNotGiven() {
        let issues = DigestValidator.problems(content(progress: [.init(text: "초안을 썼다.", status: "in_progress", anchors: ["t_999"])]), input: input())
        XCTAssertTrue(issues.contains { $0.contains("없는 앵커") }, "\(issues)")
    }

    func testRejectsCompletionWithoutEvidence() {
        let issues = DigestValidator.problems(content(progress: [.init(text: "3장을 끝냈다.", status: "evidenced", anchors: ["t_1"])]), input: input())
        XCTAssertTrue(issues.contains { $0.contains("근거 없는 완료") }, "\(issues)")
        let resolved = DigestValidator.problems(content(problems: [.init(text: "테스트 실패", state: "resolved", anchors: ["problem:test:bb"])]), input: input())
        XCTAssertTrue(resolved.contains { $0.contains("해결 근거 없는") }, "\(resolved)")
    }

    func testRejectsTooLongOutput() {
        XCTAssertFalse(DigestValidator.problems(content(summary: String(repeating: "가", count: 601)), input: input()).isEmpty)
        let many = Array(repeating: DigestContent.Item(text: "초안을 썼다.", status: "in_progress", anchors: ["t_1"]), count: 9)
        XCTAssertFalse(DigestValidator.problems(content(progress: many), input: input()).isEmpty)
    }

    func testDeterministicDigestPassesValidation() {
        XCTAssertEqual(DigestValidator.problems(DigestBuilder.deterministic(input()), input: input()), [])
        XCTAssertTrue(DigestRenderer.body(DigestBuilder.deterministic(input()), metrics: input().metrics).contains("약 6시간 20분"))
    }
}
