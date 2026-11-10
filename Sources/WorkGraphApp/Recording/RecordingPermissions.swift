import AVFoundation
import AppKit
import Speech
import WorkGraphCollectors
import WorkGraphCore

/// 녹음을 시작하지 못하게 하거나 받아쓰기를 막은 것. 메뉴 막대에 한 줄로 보이고, 누르면 고칠 수 있는 시스템 설정을 연다
enum RecordingProblem: Equatable {
    /// swift run 처럼 Info.plist 사용 문구가 없는 실행 (이때 권한을 물으면 시스템이 앱을 끝낸다)
    case notBundled
    case microphone
    case speech
    /// 시스템 설정 → 키보드 → 받아쓰기가 꺼짐 (기기 안 인식이 kLSRErrorDomain 201 로 실패)
    case dictation
    case failed(String)

    init(_ error: TranscriptionError) {
        switch error {
        case .dictationDisabled: self = .dictation
        case .speechDenied: self = .speech
        case .unavailable(let reason): self = .failed(reason)
        case .failed: self = .failed(error.message)
        }
    }

    var text: String {
        switch self {
        case .notBundled: "녹음은 설치한 앱에서만 쓸 수 있어요"
        case .microphone: "마이크 권한이 꺼져 있어요"
        case .speech: "음성 인식 권한이 꺼져 있어요"
        case .dictation: "받아쓰기가 꺼져 있어요"
        case .failed(let message): message
        }
    }

    var settingsURL: URL? {
        switch self {
        case .microphone: Permissions.settingsURL(.microphone)
        case .speech: Permissions.settingsURL(.speechRecognition)
        case .dictation: Permissions.dictationSettingsURL
        case .notBundled, .failed: nil
        }
    }

    func openSettings() {
        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }
}

/// 녹음 전 권한 확인 (테스트에서는 가짜로 바꾼다)
@MainActor
protocol RecordingPermissions {
    /// 녹음할 수 있으면 nil. 처음이면 시스템 권한 창이 뜬다
    func check() async -> RecordingProblem?
}

struct SystemRecordingPermissions: RecordingPermissions {
    func check() async -> RecordingProblem? {
        // .app 번들 밖(swift run, 테스트를 호스팅하는 xctest 등)에서는 묻지 않는다.
        // Xcode 의 xctest 호스트는 UI 테스트용으로 모든 권한 문구를 자기 Info.plist 에 미리 넣어 두므로, 문구 유무만으로는 못 가른다 (SuggestionNotifier.available 와 같은 방식)
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil else { return .notBundled }
        let info = bundle.infoDictionary ?? [:]
        guard info["NSMicrophoneUsageDescription"] != nil, info["NSSpeechRecognitionUsageDescription"] != nil else { return .notBundled }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return .microphone }
        default: return .microphone
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return nil
        case .notDetermined:
            // check() 는 MainActor 에서 돌지만, Speech 는 이 처리기를 배경 큐에서 부른다: 명시적으로 Sendable 로 표시한다
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
            }
            return status == .authorized ? nil : .speech
        default: return .speech
        }
    }
}
