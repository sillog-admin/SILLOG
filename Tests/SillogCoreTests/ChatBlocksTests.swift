import XCTest
@testable import SillogCore

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

    func testFencesSplitProseAndCode() {
        XCTAssertEqual(ChatBlocks.parts("앞 글\n```swift\nlet a = 1\n\nlet b = 2\n```\n뒤 글"), [
            .prose("앞 글"), .code(language: "swift", body: "let a = 1\n\nlet b = 2", closed: true), .prose("뒤 글"),
        ])
    }

    func testInlineBackticksAndShortClosersStayInside() {
        XCTAssertEqual(ChatBlocks.parts("문장 안의 ```x``` 는 그대로"), [.prose("문장 안의 ```x``` 는 그대로")])
        XCTAssertEqual(ChatBlocks.parts("````md\n```js\nx\n```\n````"), [.code(language: "md", body: "```js\nx\n```", closed: true)])
        XCTAssertEqual(ChatBlocks.parts("~~~\n```\n~~~"), [.code(language: "", body: "```", closed: true)])
    }

    func testCRLFAndIndentedFences() {
        XCTAssertEqual(ChatBlocks.parts("a\r\n```swift\r\nlet x\r\n```\r\nafter"), [.prose("a"), .code(language: "swift", body: "let x", closed: true), .prose("after")])
        XCTAssertEqual(ChatBlocks.parts("1. 설치\n\n    ```bash\n    brew install x\n      --flag\n    ```\n\n끝"),
                       [.prose("1. 설치\n"), .code(language: "bash", body: "brew install x\n  --flag", closed: true), .prose("\n끝")])
    }

    func testUnclosedFenceIsStreamingCode() {
        XCTAssertEqual(ChatBlocks.parts("설명\n```python\nprint(1)"), [.prose("설명"), .code(language: "python", body: "print(1)", closed: false)])
    }

    // 목록 표시처럼 보여도 아닌 것: 기울임, 음수, 줄표 두 개, 해시태그
    func testLookalikesStayText() {
        for text in ["*기울임* 문장", "-1도까지 내려가요", "-- 줄표 두 개", "#해시태그는 제목이 아니에요"] {
            XCTAssertEqual(ChatBlocks.parse(text), [.paragraph(text)], text)
        }
    }
}
