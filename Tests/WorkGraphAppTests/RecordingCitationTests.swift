import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 채팅 답의 [recording:N] 인용이 근거 칩이 된다
final class RecordingCitationTests: XCTestCase {
    func testRecordingCitationsBecomeSourceChips() {
        let source = ChatSource(id: "recording:7", title: "녹음 · 자료구조 3주차 강의", location: "/Users/me/Documents/학교/자료구조/강의.md", excerpt: "…")
        let (body, cited, missing) = ChatMessageText.citations(in: "연결 리스트는 3주차에 다뤘어요. [recording:7]", sources: [source])
        XCTAssertEqual(body, "연결 리스트는 3주차에 다뤘어요.")
        XCTAssertEqual(cited.map(\.id), ["recording:7"])
        XCTAssertFalse(missing)
    }
}
