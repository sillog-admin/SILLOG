import AppKit
import SwiftUI
import XCTest
@testable import WorkGraphApp
import WorkGraphCore

/// 활동 로그 한 줄기: 대기 기록 아래로 정리 묶음이 최신부터. 정리를 누르면 보낸 내용과 받은 응답 시트
@MainActor
final class ActivityLogLayoutTests: XCTestCase {
    private func show<V: View>(_ view: V, _ state: AppState) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(view.environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return window
    }

    private func manyBatches(_ count: Int) -> [BatchRecord] {
        let stats = #"{"resources":2,"problems":0,"topics":1,"uncoveredRows":0,"laterItems":0,"offTaskRows":0,"tasksCreated":0,"tasksMerged":0,"sessions":0,"sessionsExtended":1,"unassignedRows":0}"#
        return (1...count).reversed().map { i in
            BatchRecord(id: Int64(i), startedAt: 1_790_000_000 + Double(i) * 300, rowCount: 6, status: "ok", model: "gpt-6-luna",
                        promptTokens: 3120, completionTokens: 840, stats: stats)
        }
    }

    func testTheNewestBatchIsOnTopWhenTheListIsLong() {
        let state = AppState(preview: { s in s.phase = .ready; s.batches = self.manyBatches(120) })
        let window = show(ActivityLogView(), state)
        let text = OnboardingOverlayTests.recognizedText(window.contentView!).filter { !$0.isWhitespace }
        XCTAssertTrue(text.contains("대기"), "맨 위는 아직 보내지 않은 기록: \(text.prefix(300))")
        XCTAssertTrue(text.contains("정리#120"), "정리 120번이 쌓여도 최신 정리가 대기 바로 아래 보여야 한다: \(text.prefix(300))")
    }

    func testBatchSheetShowsAppliedResultInWords() {
        let state = AppState(preview: { s in s.phase = .ready })
        let window = show(BatchDetail(batch: manyBatches(1)[0]), state)
        let text = OnboardingOverlayTests.recognizedText(window.contentView!).filter { !$0.isWhitespace }
        XCTAssertTrue(text.contains("세션1개,새업무0개,자료2개"), "반영 결과는 JSON 이 아니라 Figma 처럼 말로: \(text.prefix(300))")
        XCTAssertFalse(text.contains("sessionsExtended"))
    }

    func testFailedBatchSaysTheErrorInOneLine() {
        var failed = manyBatches(1)[0]
        failed.status = "error"
        failed.error = #"HTTP 429: {"error":{"type":"usage_limit_reached","resets_in_seconds": 7200}}"#
        let state = AppState(preview: { s in s.phase = .ready; s.batches = [failed] })
        let window = show(ActivityLogView(), state)
        let text = OnboardingOverlayTests.recognizedText(window.contentView!).filter { !$0.isWhitespace }
        XCTAssertTrue(text.contains("사용량한도에도달했어요"), "서버 원문 대신 한 줄 안내: \(text.prefix(400))")
        XCTAssertFalse(text.contains("usage_limit_reached"), text)
    }
}
