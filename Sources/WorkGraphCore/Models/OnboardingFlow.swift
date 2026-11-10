import CoreGraphics
import Foundation

/// 온보딩 시트의 단계 (Figma OUT-01~05)
public enum OnboardingStep: Equatable, Sendable {
    /// 01 로그인
    case login
    /// 02 권한
    case permissions
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
    /// 앱 단계(phase)가 정해지거나 바뀐 뒤 보여 줄 단계. nil 이면 시트가 없다
    public static func step(after current: OnboardingStep?, phase: AppPhase) -> OnboardingStep? {
        switch phase {
        case .login: return .login                             // 로그아웃하면 언제든 1단계부터
        case .permissions: return current ?? .permissions     // 방금 로그인했으면 1단계에 머물고, 다시 실행했으면 2단계
        case .ready: return current == .login ? .login : nil  // 마친 계정이 다시 로그인했으면 성공을 보여 준 뒤 닫는다
        }
    }

    /// "로그인 완료, 다음" 을 누를 수 있는가
    public static func canAdvance(from step: OnboardingStep, phase: AppPhase) -> Bool {
        step == .login && phase != .login
    }

    /// "로그인 완료, 다음": 권한 단계가 남았으면 2단계, 이미 마친 계정이면 닫는다
    public static func advance(from step: OnboardingStep, phase: AppPhase) -> OnboardingStep? {
        guard canAdvance(from: step, phase: phase) else { return step }
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
