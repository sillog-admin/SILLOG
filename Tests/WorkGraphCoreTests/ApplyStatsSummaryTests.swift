import XCTest
@testable import WorkGraphCore

final class ApplyStatsSummaryTests: XCTestCase {
    // 활동 로그 정리 카드의 '반영 결과' 줄 (Figma LG-W3: "세션 1개, 새 업무 0개, 자료 2개"). 세션은 새로 만든 것과 이어 붙인 것을 합친다
    func testSummaryReadsLikeTheDesign() {
        let json = #"{"resources":2,"problems":1,"topics":2,"uncoveredRows":0,"laterItems":0,"offTaskRows":0,"tasksCreated":0,"tasksMerged":0,"sessions":0,"sessionsExtended":1,"unassignedRows":0}"#
        XCTAssertEqual(ApplyStats.summary(json: json), "세션 1개, 새 업무 0개, 자료 2개")
    }

    // 예전 배치는 나중에 생긴 키가 없다: 없는 키는 0
    func testSummaryReadsOlderStatsWithFewerKeys() {
        XCTAssertEqual(ApplyStats.summary(json: #"{"sessions":2,"tasksCreated":1,"resources":5}"#), "세션 2개, 새 업무 1개, 자료 5개")
    }

    func testSummaryIsNilForTextThatIsNotStats() {
        XCTAssertNil(ApplyStats.summary(json: "세션 1개"))
        XCTAssertNil(ApplyStats.summary(json: ""))
        XCTAssertNil(ApplyStats.summary(json: #"{"foo":1}"#))
    }
}
