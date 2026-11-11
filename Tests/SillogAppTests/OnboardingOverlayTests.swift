import AppKit
import SwiftUI
import Vision
import XCTest
@testable import SillogApp
import SillogCore

/// 온보딩 시트가 떠 있는 메인 창을 화면 밖 창에 그려 키보드와 포커스가 시트에만 가는지 본다
@MainActor
final class OnboardingOverlayTests: XCTestCase {
    /// 다시 로그인한 직후: 시트에는 "로그인 완료, 다음"(기본 버튼)이 켜져 있고, 시트 뒤 기록 자료의 파일 구역에도 기본 버튼 "옮기기" 가 있다
    private func signedInOverFiles() -> AppState {
        AppState(preview: { s in
            s.phase = .permissions
            s.onboardingStep = .login
            s.selectedTab = .records; s.recordsSection = .files
            s.fileSuggestions = [FileSuggestion(id: 1, ts: 0, path: "/tmp/sillog-test.pdf", fileName: "sillog-test.pdf", originUrl: nil,
                                                suggestedFolder: "/tmp", confidence: 0.9, reason: nil, source: "llm")]
        })
    }

    private func show<V: View>(_ view: V, _ state: AppState) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(view.environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        settle(window)
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testReturnGoesToTheSheetNotTheTabBehindIt() {
        let state = signedInOverFiles()
        let window = show(MainWindow(), state)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = window.performKeyEquivalent(with: enter)
        settle(window)
        // 연결 뒤에는 권한 단계 전에 판단 모델 고르기가 시트 안에 뜬다 (step 은 .login 그대로)
        XCTAssertEqual(state.onboardingStep, .login, "판단 모델 고르기는 같은 시트 안의 단계다")
        let text = Self.recognizedText(window.contentView!).filter { !$0.isWhitespace }
        XCTAssertTrue(text.contains("판단모델을골라요"), "Return 은 시트의 '로그인 완료, 다음' 을 눌러 판단 모델 고르기로 가야 한다 (시트 뒤 파일 탭의 '옮기기' 가 아니라): \(text.prefix(200))")
    }

    func testSheetTakesFocusAwayFromATextFieldBehindIt() {
        let state = AppState(preview: { s in s.phase = .ready; s.selectedTab = .records; s.recordsSection = .files })
        let window = show(MainWindow(), state)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))       // 채팅 입력칸(NSTextView) 대신
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        state.onboardingStep = .login                                                     // 인증이 끊겨 시트가 뜬 순간
        // The sheet takes focus a few run-loop turns after it appears; a fixed wait was too short on CI runners.
        let deadline = Date().addingTimeInterval(3)
        repeat { settle(window) } while window.firstResponder === field && Date() < deadline
        XCTAssertFalse(window.firstResponder === field, "시트가 뜨면 뒤의 입력칸이 타이핑을 받으면 안 된다")
    }

    func testLoginErrorCardTellsThatScreenImagesAreSent() {
        let window = show(LoginBlockedView(), AppState(preview: { s in s.phase = .login; s.loginBlocked = true }))
        let text = Self.recognizedText(window.contentView!).filter { !$0.isWhitespace }
        XCTAssertTrue(text.contains("ChatGPT계정으로시작하기"), "글자 인식이 화면을 읽어야 한다: \(text.prefix(200))")
        XCTAssertTrue(text.contains("대표화면이미지"), "W1 의 개인정보 안내도 화면 이미지가 전송된다고 말해야 한다: \(text.prefix(400))")
    }

    /// 그려진 화면의 글자 (Vision 글자 인식). SwiftUI 접근성 트리는 보조 기술이 없으면 만들어지지 않아 화면을 직접 읽는다
    static func recognizedText(_ view: NSView) -> String {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
