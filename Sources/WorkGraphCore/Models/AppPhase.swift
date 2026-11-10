import Foundation

/// 앱이 지금 어느 단계인지. ChatGPT 로그인을 해야만 쓸 수 있고, 그 전에는 수집도 정리도 돌지 않는다.
public enum AppPhase: Equatable, Sendable {
    /// 로그인 필요 (온보딩 1단계, 로그아웃 후에도 여기로 돌아온다)
    case login
    /// 로그인은 됐고 권한 안내를 아직 안 본 상태 (온보딩 2단계, 한 번만)
    case permissions
    case ready

    public static func decide(loggedIn: Bool, onboardingCompleted: Bool) -> AppPhase {
        guard loggedIn else { return .login }
        return onboardingCompleted ? .ready : .permissions
    }

    /// 수집기와 배치 실행기를 돌려도 되는 단계인가.
    public var runsServices: Bool { self == .ready }
}
