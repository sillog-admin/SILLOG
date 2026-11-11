import ApplicationServices
import Foundation

/// 브라우저의 현재 URL 찾기. AppleScript 를 쓰지 않아 추가 권한(자동화)이 필요 없다.
enum BrowserURL {
    static let browserBundles: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.naver.Whale", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium", "app.zen-browser.zen",
    ]

    static func isChrome(_ bundle: String) -> Bool {
        let id = bundle.lowercased()
        return id == "com.google.chrome" || id.hasPrefix("com.google.chrome.")
    }

    static func isBrowser(_ bundle: String) -> Bool { isChrome(bundle) || browserBundles.contains(bundle) }

    /// 접근성 없이 캡처할 때, 알려진 목록 밖의 브라우저도 앱의 웹 주소 등록 정보로 확인한다.
    static func registersWebLinks(_ info: [String: Any]) -> Bool {
        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return urlTypes.contains { type in
            let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains { ["http", "https"].contains($0.lowercased()) }
        }
    }

    /// 1) 창의 AXDocument (Safari·Chrome·Edge)  2) 첫 AXWebArea 의 AXURL  3) 주소창 텍스트 필드
    static func find(in window: AXUIElement) -> String? {
        if let document = axString(window, kAXDocumentAttribute as String), isHTTP(document) { return document }
        var visits = 0
        if let url = webAreaURL(window, depth: 0, visits: &visits) { return url }
        return addressBarURL(window, depth: 0)
    }

    static func isHTTP(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private static func webAreaURL(_ element: AXUIElement, depth: Int, visits: inout Int) -> String? {
        guard depth <= 12, visits < 300 else { return nil }
        visits += 1
        if axString(element, kAXRoleAttribute as String) == "AXWebArea",
           let url = axString(element, "AXURL"), isHTTP(url) {
            return url
        }
        for child in axChildren(element) {
            if let found = webAreaURL(child, depth: depth + 1, visits: &visits) { return found }
        }
        return nil
    }

    private static func addressBarURL(_ element: AXUIElement, depth: Int) -> String? {
        guard depth <= 5 else { return nil }
        let role = axString(element, kAXRoleAttribute as String)
        if role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String),
           let value = axString(element, kAXValueAttribute as String) {
            let text = value.trimmingCharacters(in: .whitespaces)
            if isHTTP(text) { return text }
            if !text.contains(" "), text.contains("."), text.count < 2000, !text.hasSuffix(".") { return "https://" + text }
        }
        for child in axChildren(element) {
            if let found = addressBarURL(child, depth: depth + 1) { return found }
        }
        return nil
    }
}
