import AppKit
import SwiftUI
import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 메뉴 막대의 녹음 줄: 평소, 녹음 중, 받아쓰는 중, 정리하는 중, 권한·받아쓰기 꺼짐. 그리고 빨간 점 아이콘
@MainActor
final class RecordingMenuTests: XCTestCase {
    private func menuText(_ configure: (AppState) -> Void) -> String {
        let state = AppState(preview: { s in s.phase = .ready; configure(s) })
        let host = NSHostingView(rootView: AnyView(MenuBarView().environmentObject(state)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
    }

    func testIdleShowsTheStartButton() {
        let text = menuText { _ in }
        XCTAssertTrue(text.contains("녹음시작"), text)
    }

    func testRecordingShowsTheElapsedTimeAndStop() {
        let text = menuText { s in s.activeRecording = ActiveRecording(id: 1, startedAt: Date().timeIntervalSince1970 - 751) }
        XCTAssertTrue(text.contains("녹음중12:3"), text)                       // 12:31 (그리는 사이 1초가 지날 수 있다)
        XCTAssertTrue(text.contains("끝내기"), text)
        XCTAssertFalse(text.contains("녹음시작"), text)
    }

    func testProcessingStepsAreShownAboveTheRecordButton() {
        let transcribing = menuText { s in s.recordingWork = .transcribing(0.37) }
        XCTAssertTrue(transcribing.contains("받아쓰는중37%"), transcribing)
        XCTAssertTrue(transcribing.contains("녹음시작"), "받아쓰는 동안에도 새로 녹음할 수 있다")
        let naming = menuText { s in s.recordingWork = .naming }
        XCTAssertTrue(naming.contains("녹음을정리하는중"), naming)
    }

    func testProblemsSayWhatIsOff() {
        let microphone = menuText { s in s.recordingProblem = .microphone }
        XCTAssertTrue(microphone.contains("마이크권한이꺼져있어요"), microphone)
        let dictation = menuText { s in s.recordingProblem = .dictation }
        XCTAssertTrue(dictation.contains("받아쓰기가꺼져있어요"), dictation)
    }

    func testStepTextRoundsThePercent() {
        XCTAssertEqual(RecordingPipeline.Step.transcribing(0.37).menuText, "받아쓰는 중 37%")
        XCTAssertEqual(RecordingPipeline.Step.naming.menuText, "녹음을 정리하는 중")
    }

    func testTheMenuBarIconTurnsIntoARedDotWhileRecording() {
        XCTAssertTrue(MenuBarLabel.icon(paused: false, recording: false).isTemplate)
        XCTAssertTrue(MenuBarLabel.icon(paused: true, recording: false).isTemplate)
        let dot = MenuBarLabel.icon(paused: false, recording: true)
        XCTAssertFalse(dot.isTemplate, "빨간색을 그대로 그린다")
        XCTAssertEqual(dot.accessibilityDescription, "녹음 중")
    }

    // MARK: 일시정지·권한 경고·준비 전 메뉴에서도 녹음 (수집이 일시정지돼도 녹음은 따로 돈다)

    func testPausedIdleShowsTheStartButton() {
        let text = menuText { s in s.status.running = true; s.status.paused = true }
        XCTAssertTrue(text.contains("녹음시작"), text)
    }

    func testPausedWhileRecordingShowsStopInstead() {
        let text = menuText { s in
            s.status.running = true; s.status.paused = true
            s.activeRecording = ActiveRecording(id: 1, startedAt: Date().timeIntervalSince1970 - 751)
        }
        XCTAssertTrue(text.contains("끝내기"), text)
    }

    func testPermissionMissingIdleShowsTheStartButton() {
        let text = menuText { s in s.status.running = true; s.status.accessibility = false; s.status.screenRecording = true }
        XCTAssertTrue(text.contains("녹음시작"), text)
    }

    func testNotReadyWhileRecordingShowsOnlyTheStopRow() {
        let text = menuText { s in
            s.phase = .login
            s.activeRecording = ActiveRecording(id: 1, startedAt: Date().timeIntervalSince1970 - 751)
        }
        XCTAssertTrue(text.contains("끝내기"), text)
    }

    func testNotReadyIdleHasNoStartButton() {
        let text = menuText { s in s.phase = .login }
        XCTAssertFalse(text.contains("녹음시작"), text)
    }

    // 창 머리 오른쪽 위의 녹음(메뉴 막대 아이콘이 노치 뒤로 가려질 때)은 MenuLayoutTests 가 본다
}
