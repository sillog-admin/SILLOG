import AppKit
import SwiftUI
import XCTest
@testable import SillogApp

/// Wrapped table cells grow their row instead of spilling over the next one.
@MainActor
final class ChatTableLayoutTests: XCTestCase {
    func testWrappedCellsDoNotOverlapTheNextRow() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "OCR differs on CI runners")
        let table = """
        | 우선순위 | 현재 문서에서 아쉬운 점 | 보완 방법 |
        |---|---|---|
        | 1 | 구현 항목과 수상 성과는 있지만, 기술이 얼마나 잘 작동했는지는 드러나지 않습니다. | 대표 프로젝트에 평가 조건과 실제 결과를 추가하세요. 수치가 없다면 발견한 실패와 개선 결과를 구체화하세요. |
        | 2 | 연구 목표 세 가지가 각각 큰 연구 주제여서 석사과정의 우선순위가 흐려질 수 있습니다. | 주력 주제 하나를 정하고 나머지를 확장 방향으로 배치하세요. |
        """
        let view = ChatMessageText(text: table, sources: [], onSource: { _ in })
        let host = NSHostingView(rootView: view.frame(width: 1100).padding(20).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 1140, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let text = OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
        for line in ["작동했는지는드러나지않습니다", "구체화하세요", "우선순위가흐려질수있습니다", "방향으로배치하세요"] {
            XCTAssertTrue(text.contains(line), "\(line) should read cleanly: \(text)")
        }
    }
}
