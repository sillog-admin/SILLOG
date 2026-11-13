import Foundation

/// 주제(Topic)는 "그 일이 무엇에 관한 것인가" (개념·기술·과목·문제 영역) 다.
/// 앱·웹서비스·플랫폼은 App/Resource 로, 프로젝트 이름은 Project 로 따로 기록되므로 주제에서 뺀다.
/// LLM 프롬프트에도 같은 정의를 주지만, 여기서 한 번 더 거른다.
public enum TopicFilter {
    /// 어떤 세션에서든 "쓴 도구"이지 주제가 아닌, 흔한 앱·서비스·플랫폼
    public static let platforms: Set<String> = [
        // 협업·메신저
        "github", "gitlab", "bitbucket", "discord", "slack", "notion", "zoom", "teams", "microsoft teams", "kakaotalk", "카카오톡", "kakao", "카카오", "telegram", "line", "라인",
        // AI 도구 (제품 이름. 모델·API 자체를 연구하는 일은 다른 이름으로 온다)
        "chatgpt", "claude", "claude code", "codex", "codex cli", "gemini", "copilot", "github copilot", "cursor", "perplexity",
        // 검색·메일·문서
        "google", "구글", "gmail", "google docs", "google drive", "google sheets", "google slides", "naver", "네이버", "daum", "다음", "bing",
        // 브라우저·편집기·IDE·유틸
        "chrome", "google chrome", "safari", "whale", "firefox", "edge", "arc", "vs code", "vscode", "visual studio code", "xcode", "intellij", "pycharm",
        "finder", "terminal", "터미널", "iterm", "obsidian", "dbeaver", "postman", "figma", "miro", "excalidraw", "preview", "미리보기",
        // 강의 사이트·영상·SNS
        "lms", "blackboard", "youtube", "유튜브", "netflix", "instagram", "인스타그램", "twitter", "x", "facebook", "페이스북",
        "reddit", "linkedin", "tiktok", "chzzk", "치지직", "twitch", "stack overflow", "stackoverflow", "velog", "tistory", "medium",
    ]

    /// 뜻이 없는 채움말
    public static let filler: Set<String> = ["기타", "일반", "기본", "없음", "미분류", "잡다", "기타 등등", "etc", "etc.", "misc", "other", "others", "general", "unknown", "n/a", "none", "-", "uncategorized", "miscellaneous", "various"]

    /// 파일 이름이 주제로 오는 경우 ("lab.ipynb"). Node.js 같은 기술 이름과 겹치지 않는 확장자만
    static let fileExtensions: Set<String> = ["pdf", "ipynb", "py", "swift", "md", "txt", "docx", "doc", "pptx", "ppt", "xlsx", "xls", "csv", "json", "yaml", "yml",
                                              "html", "css", "ts", "tsx", "jsx", "java", "kt", "c", "cpp", "h", "rs", "go", "sh", "zip", "png", "jpg", "jpeg", "gif",
                                              "mp4", "mov", "hwp", "hwpx", "sql", "sqlite", "plist", "xml", "tex", "ttl", "cypher", "dmg", "pkg", "app"]

    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#.,;:!?\"'()[]{}"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// 공백·구두점을 없앤 느슨한 형태 ("VS Code" = "vscode", "Claude Code" = "claudecode")
    static func loose(_ text: String) -> String {
        var name = normalize(text)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name.replacingOccurrences(of: "[\\s._-]+", with: "", options: .regularExpression)
    }

    /// 걸러야 하는 이유. nil 이면 주제로 둔다.
    public static func rejection(_ topic: String, apps: Set<String>, projects: Set<String>) -> String? {
        let name = normalize(topic)
        guard !name.isEmpty else { return "빈 값" }
        if filler.contains(name) { return "채움말" }
        let looseName = loose(name)
        guard !looseName.isEmpty else { return "빈 값" }
        if !name.contains(" "), let dot = name.lastIndex(of: "."), fileExtensions.contains(String(name[name.index(after: dot)...])) { return "파일 이름" }
        if platforms.contains(name) || platforms.contains { loose($0) == looseName } { return "플랫폼·서비스" }
        if apps.contains(where: { loose($0) == looseName }) { return "앱" }
        if projects.contains(where: { loose($0) == looseName }) { return "프로젝트 이름" }
        return nil
    }

    /// 주제 목록에서 앱·플랫폼·프로젝트·채움말을 빼고, 같은 것은 하나로 (원래 표기는 처음 것)
    public static func clean(_ topics: [String], apps: Set<String>, projects: Set<String>) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for topic in topics {
            let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rejection(trimmed, apps: apps, projects: projects) == nil, seen.insert(normalize(trimmed)).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
