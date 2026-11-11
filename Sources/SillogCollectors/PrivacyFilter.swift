import Foundation

/// 기록하지 않을 앱과 창을 정한다. 제외된 동안에도 "제외된 앱"이라는 빈 행은 남겨서
/// 앞 행의 체류시간이 그 시간까지 늘어나지 않게 한다.
public struct PrivacyFilter: Sendable {
    public static let defaultExcludedBundles: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.loginwindow", "com.apple.screencaptureui", "com.apple.ScreenSaver.Engine",
    ]

    /// 설정의 제외 목록과 상관없이 늘 뺀다: 시스템 인증 창 (Touch ID 확인 coreautha, 암호 확인 SecurityAgent).
    /// 키체인 접근 같은 제외 앱을 열 때 뜨는 창이라, 목록에 없으면 안내 문구와 화면이 기록되고 전송된다.
    /// 저장된 설정에는 예전 기본 목록이 남아 있으므로 기본 목록이 아니라 여기에 둔다.
    public static let alwaysExcludedBundles: Set<String> = [
        "com.apple.LocalAuthentication.UIAgent", "com.apple.SecurityAgent",
    ]

    /// 시크릿/프라이빗 창 제목 표식. "private" 단독은 오탐이 많아 넣지 않는다 ("Private API docs" 등).
    static let privateTitleHints = [
        "incognito", "inprivate", "private browsing", "private window", "private mode", "- private", "(private)",
        "시크릿", "개인정보 보호 브라우징", "프라이빗 브라우징", "개인 정보 보호 브라우징",
    ]

    /// 실록 자신의 번들 ID. `swift run` 처럼 번들 없이 실행하면 ID 가 없어서, 수집기가 번들 없는 앱에 붙이는 이름으로 대신한다
    public static let selfBundle = Bundle.main.bundleIdentifier ?? "unknown.\(ProcessInfo.processInfo.processName)"

    public var excludedBundles: Set<String>

    public init(excludedBundles: Set<String> = PrivacyFilter.defaultExcludedBundles) {
        self.excludedBundles = excludedBundles
    }

    public func isExcluded(bundle: String) -> Bool {
        excludedBundles.contains(bundle) || Self.alwaysExcludedBundles.contains(bundle) || bundle == Self.selfBundle
    }

    /// 기본 제외 목록의 표시 이름 (설치되지 않은 앱도 이름은 보여주기 위해)
    public static let defaultNames: [String: String] = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7", "com.bitwarden.desktop": "Bitwarden",
        "com.lastpass.LastPass": "LastPass", "com.dashlane.dashlanephonefinal": "Dashlane", "org.keepassxc.keepassxc": "KeePassXC",
        "com.apple.keychainaccess": "키체인 접근", "com.apple.Passwords": "암호", "com.apple.loginwindow": "로그인 창",
        "com.apple.screencaptureui": "스크린샷 도구", "com.apple.ScreenSaver.Engine": "화면 보호기",
    ]

    public func isPrivateWindow(title: String?) -> Bool {
        guard let lower = title?.lowercased(), !lower.isEmpty else { return false }
        return Self.privateTitleHints.contains { lower.contains($0) }
    }

    /// 이 창을 찍고 OCR 해도 되는지. 비공개 창은 접근성으로 읽은 창 제목으로만 가릴 수 있어서,
    /// 제목이 없을 때(기기 제어 권한 없음) 브라우저는 찍지 않는다. 창 목록의 이름에는 시크릿 표식이 없다.
    public func mayCapture(bundle: String, windowTitle: String?) -> Bool {
        guard !isExcluded(bundle: bundle), !isPrivateWindow(title: windowTitle) else { return false }
        return !(windowTitle ?? "").isEmpty || !BrowserURL.isBrowser(bundle)
    }
}
