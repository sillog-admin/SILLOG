import Foundation

/// 자료가 아닌 페이지: 검색 결과, 빈 탭, 로그인·리다이렉트, 목록만 스친 것. 세션의 자료로 잇지 않고 다시 열지도 않는다.
/// 의미 판단이 아니라 데이터 정리다 (검색 결과 페이지는 누가 봐도 "다시 볼 자료"가 아니다).
public enum TransientPages {
    static let blankTitles: Set<String> = ["", "제목 없음", "untitled", "새 탭", "new tab", "빈 페이지", "about:blank", "loading…", "loading..."]

    public static func isTransient(url: String?, title: String?) -> Bool {
        if let title, blankTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return true }
        guard let url, let components = URLComponents(string: url), let host = components.host?.lowercased() else { return false }
        let path = components.path.lowercased(), query = components.query?.lowercased() ?? ""
        if host.hasSuffix("google.com") || host.hasSuffix("google.co.kr") { return path.hasPrefix("/search") || path == "/" || path.isEmpty }
        if host == "search.naver.com" || host == "search.daum.net" || host == "duckduckgo.com" { return true }
        if host == "www.bing.com" && path.hasPrefix("/search") { return true }
        if host == "www.youtube.com" && path == "/results" { return true }
        if path.contains("/login") || path.contains("/signin") || path.contains("/oauth") || path.contains("/logout") || query.contains("error=") { return true }
        if host == "github.com" && (path == "/new" || path == "/login" || path == "/notifications" || path == "/") { return true }
        if host == "accounts.google.com" || host == "auth.openai.com" || host == "id.atlassian.com" { return true }
        return false
    }
}
