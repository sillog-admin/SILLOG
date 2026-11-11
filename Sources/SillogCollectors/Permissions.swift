import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import SillogCore

/// 수집에 필요한 macOS 권한 확인·요청. 권한이 없으면 해당 수집기만 꺼지고 나머지는 계속 돈다.
public enum Permissions {
    public enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case filesAndFolders = "Privacy_FilesAndFolders"
        case microphone = "Privacy_Microphone"
        case speechRecognition = "Privacy_SpeechRecognition"
    }

    /// 시스템 설정에 보이는 손쉬운 사용(접근성) 권한 이름. macOS 27 은 '기기 제어 및 데이터 접근'으로 부른다
    public static var accessibilityName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "기기 제어 및 데이터 접근" : "손쉬운 사용"
    }

    /// 손쉬운 사용(접근성): 창 제목, URL, 문서 경로, 화면 텍스트에 필요.
    public static func accessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        if prompt { AppLog.write("손쉬운 사용 요청 -> \(trusted ? "허용됨" : "아직 허용 안 됨")") }
        return trusted
    }

    /// 화면 기록: 스크린샷과 OCR 에 필요.
    public static func screenRecording() -> Bool { CGPreflightScreenCaptureAccess() }

    /// 시스템 권한 창을 띄우고, 시스템 설정의 "화면 및 시스템 오디오 녹음" 목록에 이 앱을 등록시킨다.
    /// 허용 후에는 앱을 다시 실행해야 적용된다.
    public static func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        let granted = CGRequestScreenCaptureAccess()
        AppLog.write("화면 기록 요청: CGRequestScreenCaptureAccess -> \(granted ? "허용됨" : "아직 허용 안 됨")")
        // macOS 15 에서는 위 호출만으로 목록에 안 올라오는 경우가 있다.
        // 실제 캡처 API 를 한 번 건드리면 시스템이 앱을 목록에 등록하고 허용 여부를 묻는다.
        Task.detached(priority: .userInitiated) {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                AppLog.write("화면 기록 요청: 캡처 API 확인 -> 접근 가능")
            } catch {
                let nsError = error as NSError
                AppLog.write("화면 기록 요청: 캡처 API 확인 -> 거부됨 (\(nsError.domain) \(nsError.code)). 시스템 설정 목록에 등록됨")
            }
        }
    }

    public static func settingsURL(_ pane: Pane) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
    }

    /// 시스템 설정 → 키보드 (받아쓰기 켜기는 이 화면 아래쪽에 있다)
    public static let dictationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    public static func openSettings(_ pane: Pane) {
        if let url = settingsURL(pane) { NSWorkspace.shared.open(url) }
    }
}
