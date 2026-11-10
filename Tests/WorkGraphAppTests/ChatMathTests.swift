import AppKit
import SwiftUI
import XCTest
@testable import WorkGraphApp

/// 채팅 답의 LaTeX 수식: 문단에서 수식을 찾아 앱 안에서 그린다
@MainActor
final class ChatMathTests: XCTestCase {
    /// 사용자가 본 예: 두 행렬을 나란히 (\[ … \] 블록, \text{①}, \qquad, pmatrix)
    static let matrices = #"\text{① }\begin{pmatrix}1&0\\0&1\end{pmatrix}\qquad\text{② }\begin{pmatrix}1&1\\1&1\end{pmatrix}"#

    func testFindsBlockAndInlineMath() {
        XCTAssertEqual(ChatMath.segments("두 행렬\n\\[\n\(Self.matrices)\n\\]"), [.text("두 행렬\n"), .block(Self.matrices)])
        XCTAssertEqual(ChatMath.segments("$$x^2+1$$"), [.block("x^2+1")])
        XCTAssertEqual(ChatMath.segments("넓이는 $\\pi r^2$ 이고 \\(a+b\\) 도 있다"),
                       [.text("넓이는 "), .inline("\\pi r^2"), .text(" 이고 "), .inline("a+b"), .text(" 도 있다")])
    }

    func testLeavesMoneyCodeAndUnclosedDollarsAlone() {
        XCTAssertEqual(ChatMath.segments("가격은 $5 에서 $10 사이"), [.text("가격은 $5 에서 $10 사이")])
        XCTAssertEqual(ChatMath.segments("`$HOME/bin` 과 `$PATH`"), [.text("`$HOME/bin` 과 `$PATH`")])
        XCTAssertEqual(ChatMath.segments("끝나지 않은 $x"), [.text("끝나지 않은 $x")])
    }

    func testRendersTheMatrixExampleIncludingKoreanText() {
        XCTAssertNotNil(ChatMath.render(Self.matrices, display: true), "행렬·\\text·\\qquad 를 그릴 수 있어야 한다")
        XCTAssertNotNil(ChatMath.render(#"\text{넓이} = \frac{1}{2}ab"#, display: false), "\\text 안의 한글도 대체 글꼴로")
        XCTAssertNil(ChatMath.render(#"\frac{1}{"#, display: true), "깨진 LaTeX 는 nil (원문을 그대로 보여 주게)")
    }

    func testChatShowsMathInsteadOfLatexSource() {
        let view = ChatMessageText(text: "두 행렬을 비교하면\n\n\\[\n\(Self.matrices)\n\\]\n\n①은 항등행렬이에요.", sources: [], onSource: { _ in })
        let host = NSHostingView(rootView: view.frame(width: 640).padding(20).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let text = OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
        XCTAssertTrue(text.contains("두행렬을비교하면"), "앞뒤 문단은 그대로: \(text)")
        XCTAssertFalse(text.contains("pmatrix") || text.contains("begin"), "LaTeX 원문이 아니라 그려진 수식이어야 한다: \(text)")
    }
}
