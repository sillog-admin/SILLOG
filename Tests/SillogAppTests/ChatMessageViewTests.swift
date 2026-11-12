import AppKit
import SwiftUI
import Vision
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

    func testMessageTextRedrawsOnlyWhenTextOrSourcesChange() {
        let a = ChatMessageText(text: "x", sources: [], onSource: { _ in })
        XCTAssertEqual(a, ChatMessageText(text: "x", sources: [], onSource: { _ in print("other") }), "a new closure is not a change")
        XCTAssertNotEqual(a, ChatMessageText(text: "xy", sources: [], onSource: { _ in }))
    }

    func testInlineCodeHasABackground() {
        let text = ChatMessageText.inlineMarkdown("a `b` c")
        let code = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code.count, 1)
        XCTAssertNotNil(code.first?.backgroundColor)
        XCTAssertNil(text.runs.first?.backgroundColor)
    }

    func testTheSourceSheetOpensOnlyNodesWithAnOpenableKey() {
        let node = { ChatSource(id: "node:1", title: "Paper · x", location: $0, excerpt: "") }
        XCTAssertTrue(ChatSourceSheet.opensNode(node("doi:10.1/x")))
        XCTAssertTrue(ChatSourceSheet.opensNode(node("file:~/notes.md")))
        XCTAssertFalse(ChatSourceSheet.opensNode(node("task:chat-citations")))
        XCTAssertFalse(ChatSourceSheet.opensNode(ChatSource(id: "card:1", title: "x", location: "doi:10.1/x", excerpt: "")))
    }

    // MARK: work-log toggle hit area

    private func finishedAnswer() throws -> (NSWindow, NSHostingView<AnyView>) {
        let database = try SillogDatabase.inMemory()
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
        let chat = ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
        let id = chat.current.id
        var answer = ConversationMessage(conversationID: id, role: "assistant",
                                         text: "이번 주에는 채팅 화면을 주로 다듬었습니다. 인용 칩과 작업 기록, 출처 시트를 고쳤고 긴 대화의 기억도 손봤습니다.\n\n남은 일은 모델 선택 위치와 피드백 단추입니다. 둘 다 다음 주에 정하기로 했습니다.")
        answer.status = "complete"
        answer.trace = [ChatStep(title: "기록 검색", status: .done), ChatStep(title: "기간 집계", status: .done), ChatStep(title: "결과물 생성", status: .done)]
        chat.messages = [.init(conversationID: id, role: "user", text: "이번 주 정리해줘"), answer]
        let state = AppState(preview: { s in s.phase = .ready; s.selectedTab = .chat; s.chat = chat })
        let host = NSHostingView(rootView: AnyView(MainWindow().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        // SwiftUI buttons ignore events sent to a window that was never ordered in; keep it off every screen.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        settle(host)
        return (window, host)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// Returns: recognized lines with their boxes in the view's own coordinates.
    private func lines(_ view: NSView) -> [(String, CGRect)] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let size = view.bounds.size
        return (request.results ?? []).compactMap { result in
            result.topCandidates(1).first.map { ($0.string.filter { !$0.isWhitespace },
                CGRect(x: result.boundingBox.minX * size.width,
                       y: (view.isFlipped ? 1 - result.boundingBox.maxY : result.boundingBox.minY) * size.height,
                       width: result.boundingBox.width * size.width, height: result.boundingBox.height * size.height)) }
        }
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }

    func testOnlyTheSummaryLineTogglesTheWorkLog() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "OCR reads CI screens differently")
        let (window, host) = try finishedAnswer()
        let before = lines(host)
        let summary = try XCTUnwrap(before.first { $0.0.contains("작업3단계") }?.1, before.map(\.0).joined(separator: "\n"))
        let text = try XCTUnwrap(before.first { $0.0.contains("남은일은") }?.1, before.map(\.0).joined(separator: "\n"))
        XCTAssertFalse(before.contains { $0.0.contains("기간집계") })

        let first = try XCTUnwrap(before.first { $0.0.contains("이번주에는") }?.1)
        for (name, point) in [("text", NSPoint(x: text.midX, y: text.midY)), ("gap", NSPoint(x: text.minX + 20, y: (first.maxY + text.minY) / 2)),
                              ("right of summary", NSPoint(x: summary.maxX + 200, y: summary.midY)), ("right of text", NSPoint(x: text.maxX + 40, y: text.midY))] {
            click(window, at: host.convert(point, to: nil))
            settle(host)
            XCTAssertFalse(lines(host).contains { $0.0.contains("기간집계") }, "clicking \(name) opened the work log")
        }

        click(window, at: host.convert(NSPoint(x: summary.minX + 10, y: summary.midY), to: nil))
        settle(host)
        XCTAssertTrue(lines(host).contains { $0.0.contains("기간집계") }, "clicking the summary line did not open the work log")
    }
}
