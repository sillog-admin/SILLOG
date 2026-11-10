import Foundation

/// 메뉴 막대 드롭다운이 그릴 화면 (Figma OUT-W2, OUT-W7, OUT-W6, OUT-06)
public enum MenuBarMode: Equatable, Sendable {
    /// W2: 로그인 전, 권한 단계를 마치기 전, 시작 실패
    case notReady
    /// W7: 수집 일시정지
    case paused
    /// W6: 손쉬운 사용이나 화면 기록이 꺼져 있음
    case permissionMissing
    /// OUT-06: 정상
    case normal
}

/// 메뉴 막대에 보일 화면과 문구
public enum MenuBarModel {
    /// 고르는 순서: 준비 전 → 일시정지 → 권한 빠짐 → 정상.
    /// 권한은 수집기가 처음 알려 주기 전(running == false)에는 모르는 값이라 경고하지 않는다.
    public static func mode(phase: AppPhase, startupFailed: Bool, paused: Bool, running: Bool,
                            accessibility: Bool, screenRecording: Bool) -> MenuBarMode {
        if startupFailed || phase != .ready { return .notReady }
        if paused { return .paused }
        if running, !accessibility || !screenRecording { return .permissionMissing }
        return .normal
    }

    /// W2 의 안내 한 줄
    public static func notReadyMessage(phase: AppPhase, startupFailed: Bool) -> String {
        if startupFailed { return "Sillog을 시작하지 못했어요" }
        return phase == .login ? "시작하려면 ChatGPT 로그인이 필요해요" : "시작하려면 권한 설정을 마쳐 주세요"
    }

    /// 오른쪽 위 상태 글씨. 준비 전에는 없다
    public static func statusText(mode: MenuBarMode, running: Bool, idle: Bool) -> String? {
        switch mode {
        case .notReady: return nil
        case .paused: return "일시정지됨"
        case .permissionMissing: return "■ 수집 중"
        case .normal: return idle ? "자리 비움" : running ? "■ 기록 중" : "시작하는 중"
        }
    }

    /// 큰 숫자: 10 미만은 "06" 처럼 두 자리, 음수는 0
    public static func twoDigits(_ value: Int) -> String {
        let n = max(0, value)
        return n < 10 ? "0\(n)" : "\(n)"
    }

    /// 마지막 정리 요약: "14:05 정리 완료(새 업무 1개, 자료 3개)"
    public static func batchSummary(clock: String, newTasks: Int, resources: Int) -> String {
        "\(clock) 정리 완료(새 업무 \(newTasks)개, 자료 \(resources)개)"
    }
}
