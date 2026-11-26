import CoreGraphics
import Foundation

/// Onboarding sheet steps, in order (Figma OUT-00~05).
public enum OnboardingStep: Equatable, Sendable {
    /// Asked before anything else on first launch, so the rest reads in the chosen language.
    case language
    case login
    case permissions
    /// Whether SUMUNJANG holds back sensitive screens; the last step, so its button starts the app.
    case privacy
}

/// 온보딩 권한 단계가 읽는 두 권한
public struct PermissionGrants: Equatable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public var all: Bool { accessibility && screenRecording }
}

/// 온보딩 시트를 언제, 어느 단계로 보여 줄지. 로그인이 끝나도 사용자가 "로그인 완료, 다음" 을 누를 때까지 1단계에 머문다.
public enum OnboardingFlow {
    /// Args: current is the step on screen, phase the app phase just decided, askLanguage whether onboarding is unfinished and no language was chosen yet.
    /// Returns: the step to show next, or nil for no sheet.
    /// Raises: none.
    public static func step(after current: OnboardingStep?, phase: AppPhase, askLanguage: Bool) -> OnboardingStep? {
        switch phase {
        case .login:                                           // a logout always goes back to login, past the language step
            return current == .language || (current == nil && askLanguage) ? .language : .login
        case .permissions:                                     // a fresh login stays on login; a relaunch opens permissions, or language if unasked
            return current ?? (askLanguage ? .language : .permissions)
        case .ready: return current == .login ? .login : nil  // a finished account that logs in again sees success, then the sheet closes
        }
    }

    /// Args: step is the step on screen, phase the app phase.
    /// Returns: whether its Next button works: always on the language and permission steps, on login only once connected.
    /// Raises: none.
    public static func canAdvance(from step: OnboardingStep, phase: AppPhase) -> Bool {
        step == .language || step == .permissions || (step == .login && phase != .login)
    }

    /// Args: step is the step on screen, phase the app phase.
    /// Returns: the step after Next: login if not connected yet, then permissions and privacy if left, else nil to close.
    /// Raises: none.
    public static func advance(from step: OnboardingStep, phase: AppPhase) -> OnboardingStep? {
        guard canAdvance(from: step, phase: phase) else { return step }
        if phase == .login { return .login }
        if step == .permissions { return .privacy }
        return phase == .permissions ? .permissions : nil
    }

    /// 닫기(×): 창은 닫히고, 남은 단계가 있으면 창을 다시 열 때 그 단계가 보인다
    public static func close(_ step: OnboardingStep?, phase: AppPhase) -> OnboardingStep? {
        phase == .ready ? nil : step
    }

    /// "수집 시작" 을 진하게 보일지 (누르는 것은 언제나 된다).
    /// 두 권한이 있고 다시 실행할 일이 없을 때만 진하다 (OUT-05 는 다시 실행 전이라 흐림)
    public static func startLooksReady(_ grants: PermissionGrants, askedScreenRecording: Bool) -> Bool {
        grants.all && !askedScreenRecording
    }

    /// 시트 위치: 탭 막대(54) 바로 아래(53)에 붙이고, 창이 낮아 안 들어가면 가운데, 그래도 넘치면 맨 위(넘친 만큼은 스크롤)
    public static func sheetTop(available: CGFloat, card: CGFloat) -> CGFloat {
        let belowTabs: CGFloat = 53
        if belowTabs + card <= available { return belowTabs }
        return max(0, (available - card) / 2)
    }
}
