import XCTest
@testable import WorkGraphCore

/// 측정에서 앱이 거부할 판정을 성공으로 세지 않도록, 앱과 같은 검증을 해 본다
final class AssignmentCheckTests: XCTestCase {
    private let open = TaskDigest(id: "t_a", title: "대시보드 카드 UI 구현", taskType: "코드작성", topics: [], recentResources: [],
                                  lastActive: 0, recentSummaries: [], goal: "카드를 만든다")

    func testACompletePatchOnAnOpenTaskPasses() throws {
        let patch = try Fixtures.patch(#"{"tasks":[{"ref":"A","match":"existing","id":"t_a"}],"rows":[{"rows":"1-5","task":"A"},{"rows":"6","task":null}]}"#)
        XCTAssertNil(AssignmentCheck.rejection(patch, rows: Fixtures.frontendRows(), openTasks: [open], now: 2_000_000))
    }

    func testAnUndefinedRefIsRejectedLikeTheApp() throws {
        let patch = try Fixtures.patch(#"{"tasks":[],"rows":[{"rows":"1-5","task":"none"},{"rows":"6","task":null}]}"#)
        XCTAssertNotNil(AssignmentCheck.rejection(patch, rows: Fixtures.frontendRows(), openTasks: [open], now: 2_000_000))
    }

    func testAMissingRowIsRejectedLikeTheApp() throws {
        let patch = try Fixtures.patch(#"{"tasks":[{"ref":"A","match":"existing","id":"t_a"}],"rows":[{"rows":"1-5","task":"A"}]}"#)
        XCTAssertNotNil(AssignmentCheck.rejection(patch, rows: Fixtures.frontendRows(), openTasks: [open], now: 2_000_000))
    }
}
