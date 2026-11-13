import XCTest
@testable import SillogApp

final class LibraryTextInfoTests: XCTestCase {
    func testOfficeTextPreviewSkipsThePartNameLine() {
        let info = LibraryTextInfo.from("[word/document.xml]\n주간 업무 보고\n이번 주 정리")
        XCTAssertEqual(info.first, "주간 업무 보고")
    }
}
