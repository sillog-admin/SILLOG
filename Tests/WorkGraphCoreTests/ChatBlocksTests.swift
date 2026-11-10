import XCTest
@testable import WorkGraphCore

/// 채팅 본문 한 덩어리(빈 줄 사이)를 줄 단위 블록으로: 제목, 문단, 목록, 인용, 구분선
final class ChatBlocksTests: XCTestCase {
    func testHeadingTakesOnlyItsOwnLine() {
        XCTAssertEqual(ChatBlocks.parse("## 제목 바로 다음 줄\n본문이 제목 아래 바로 붙은 경우"),
                       [.heading(2, "제목 바로 다음 줄"), .paragraph("본문이 제목 아래 바로 붙은 경우")])
    }

    func testListsKeepLevelsNumbersAndContinuationLines() {
        let list = ChatBlocks.parse("- 글머리 하나\n- 글머리 둘\n  - 들여 쓴 하위 항목\n  이어지는 줄\n1. 번호 하나\n2) 번호 둘\n* 별표 글머리")
        XCTAssertEqual(list, [.list([
            .init(level: 0, marker: "•", text: "글머리 하나"), .init(level: 0, marker: "•", text: "글머리 둘"),
            .init(level: 1, marker: "•", text: "들여 쓴 하위 항목\n이어지는 줄"),
            .init(level: 0, marker: "1.", text: "번호 하나"), .init(level: 0, marker: "2)", text: "번호 둘"),
            .init(level: 0, marker: "•", text: "별표 글머리"),
        ])])
    }

    func testQuoteAndDivider() {
        XCTAssertEqual(ChatBlocks.parse("> 인용문입니다.\n> 이어지는 인용\n---\n***"), [.quote("인용문입니다.\n이어지는 인용"), .divider, .divider])
    }

    func testTextAroundBlocksStaysParagraphs() {
        XCTAssertEqual(ChatBlocks.parse("앞 문단\n- 항목\n뒤 문단"), [.paragraph("앞 문단"), .list([.init(level: 0, marker: "•", text: "항목")]), .paragraph("뒤 문단")])
    }

    // 목록 표시처럼 보여도 아닌 것: 기울임, 음수, 줄표 두 개, 해시태그
    func testLookalikesStayText() {
        for text in ["*기울임* 문장", "-1도까지 내려가요", "-- 줄표 두 개", "#해시태그는 제목이 아니에요"] {
            XCTAssertEqual(ChatBlocks.parse(text), [.paragraph(text)], text)
        }
    }
}
