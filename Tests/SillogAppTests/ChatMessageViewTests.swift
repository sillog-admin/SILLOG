import SwiftUI
import XCTest
@testable import SillogApp
@testable import SillogCore

/// A failed answer keeps what arrived apart from its error, and inline code gets a background.
@MainActor
final class ChatMessageViewTests: XCTestCase {
    func testAFailedAnswerSplitsTheReceivedTextFromTheError() {
        let parts = ChatView.failureParts("## 이번 주\n- 정리\n\n응답을 완료하지 못했습니다: 연결이 끊겼습니다.")
        XCTAssertEqual(parts.received, "## 이번 주\n- 정리")
        XCTAssertEqual(parts.error, "응답을 완료하지 못했습니다: 연결이 끊겼습니다.")
        XCTAssertEqual(ChatView.failureParts("\n\nCouldn't finish the response: timeout").received, "")
        XCTAssertEqual(ChatView.failureParts("\n\nCouldn't finish the response: timeout").error, "Couldn't finish the response: timeout")
        XCTAssertEqual(ChatView.failureParts("unexpected").error, "unexpected")
    }

    func testInlineCodeHasABackground() {
        let text = ChatMessageText.inlineMarkdown("a `b` c")
        let code = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code.count, 1)
        XCTAssertNotNil(code.first?.backgroundColor)
        XCTAssertNil(text.runs.first?.backgroundColor)
    }
}
