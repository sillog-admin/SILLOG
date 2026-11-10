import Foundation

public struct ClassifiedResource: Equatable, Sendable {
    public let key: String
    public let subtype: String
    public let title: String
    public let projectKey: String?
    public let projectTitle: String?

    public init(key: String, subtype: String, title: String, projectKey: String? = nil, projectTitle: String? = nil) {
        self.key = key; self.subtype = subtype; self.title = title
        self.projectKey = projectKey; self.projectTitle = projectTitle
    }
}

/// LLM 없이 확장자·도메인·창 제목만으로 자료의 종류(ResourceType)를 정한다.
public enum RuleClassifier {
    static let codeExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "kts", "c", "h", "cpp", "hpp", "cc",
        "m", "mm", "cs", "php", "html", "css", "scss", "vue", "svelte", "sql", "sh", "zsh", "yaml", "yml", "json", "toml",
        "ipynb", "dart", "lua", "r", "gradle", "xml",
    ]
    static let noteExtensions: Set<String> = ["md", "markdown", "txt", "org", "rtf"]
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "hwp", "hwpx", "pages", "ppt", "pptx", "key", "xls", "xlsx", "numbers", "csv",
    ]
    static let designExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "fig", "sketch", "psd", "ai", "heic", "webp"]
    static let projectMarkers = [".git", "package.json", "Package.swift", "pyproject.toml", "Cargo.toml", "go.mod",
                                 "pom.xml", "build.gradle", "requirements.txt", "Gemfile", "pubspec.yaml"]
    static let editorBundlePrefixes = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode",
                                       "com.jetbrains.", "com.sublimetext.", "com.vscodium", "com.exafunction.windsurf",
                                       "com.google.android.studio"]
    static let editorNameHints = ["visual studio code", "cursor", "zed", "xcode", "windsurf", "sublime", "intellij",
                                  "pycharm", "webstorm", "android studio", "vscodium"]

    public static func classify(appBundle: String, appName: String, windowTitle: String?, url: String?, docPath: String?,
                                home: String, fileExists: (String) -> Bool) -> ClassifiedResource? {
        if let url, isHTTP(url) {
            let key = URINormalizer.normalize(url: url)
            return ClassifiedResource(key: key, subtype: webSubtype(forKey: key),
                                      title: cleanTitle(windowTitle) ?? key)
        }
        if let docPath, !docPath.isEmpty {
            return classifyFile(docPath, home: home, fileExists: fileExists)
        }
        if isEditor(bundle: appBundle, name: appName), let parsed = parseEditorTitle(windowTitle, appName: appName) {
            let ext = (parsed.file as NSString).pathExtension.lowercased()
            let subtype = noteExtensions.contains(ext) ? "Note" : "CodeFile"
            let key = parsed.workspace.map { "code:\($0)/\(parsed.file)" } ?? "code:\(parsed.file)"
            return ClassifiedResource(key: key, subtype: subtype, title: parsed.file,
                                      projectKey: parsed.workspace.map { "project:\($0)" }, projectTitle: parsed.workspace)
        }
        return nil
    }

    // MARK: 웹

    static func isHTTP(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    static func webSubtype(forKey key: String) -> String {
        if key.hasPrefix("local:") { return "Preview" }
        if key.hasPrefix("arxiv:") || key.hasPrefix("doi:") { return "Paper" }
        guard let comps = URLComponents(string: key), let host = comps.host?.lowercased() else { return "WebPage" }
        let path = comps.path.lowercased()
        let segments = Set(path.split(separator: "/").map(String.init))
        func hostIs(_ domains: String...) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }

        if hostIs("openreview.net", "aclanthology.org", "semanticscholar.org", "ieeexplore.ieee.org", "dl.acm.org",
                  "scholar.google.com", "dbpia.co.kr", "riss.kr", "kci.go.kr", "sciencedirect.com", "springer.com", "nature.com") {
            return "Paper"
        }
        if hostIs("youtube.com", "youtu.be", "vimeo.com", "twitch.tv", "inflearn.com", "udemy.com", "coursera.org") { return "Video" }
        if hostIs("stackoverflow.com", "stackexchange.com", "superuser.com", "serverfault.com", "askubuntu.com", "reddit.com", "okky.kr") {
            return "QnA"
        }
        if hostIs("github.com", "gitlab.com"), segments.contains("issues") || segments.contains("discussions") { return "QnA" }
        if hostIs("chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "perplexity.ai",
                  "copilot.microsoft.com", "wrtn.ai", "chat.deepseek.com", "grok.com") {
            return "AIChat"
        }
        if hostIs("colab.research.google.com", "kaggle.com", "codesandbox.io", "stackblitz.com", "replit.com") { return "CodeFile" }
        if hostIs("figma.com", "canva.com", "miro.com", "excalidraw.com") { return "Design" }
        if hostIs("notion.so", "notion.site", "obsidian.md") { return "Note" }
        if host == "docs.google.com" || hostIs("office.com", "hancomdocs.com", "overleaf.com") { return "Document" }
        if hostIs("mail.google.com", "outlook.live.com", "outlook.office.com", "mail.naver.com", "slack.com",
                  "discord.com", "teams.microsoft.com", "web.whatsapp.com") {
            return "Message"
        }
        let docHosts = ["developer.apple.com", "developer.mozilla.org", "learn.microsoft.com", "pkg.go.dev", "docs.rs",
                        "devdocs.io", "swiftpackageindex.com", "readthedocs.io", "readthedocs.org"]
        let docSegments: Set<String> = ["docs", "doc", "documentation", "reference", "guide", "guides", "manual",
                                        "api", "tutorial", "tutorials", "handbook", "learn"]
        if host.hasPrefix("docs.") || host.hasPrefix("developer.") || docHosts.contains(where: { hostIs($0) })
            || !segments.isDisjoint(with: docSegments) {
            return "Documentation"
        }
        return "WebPage"
    }

    /// "Card - shadcn/ui - Google Chrome" → "Card - shadcn/ui"
    static func cleanTitle(_ title: String?) -> String? {
        guard var text = title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let browsers = "Google Chrome|Chrome|Safari|Arc|Microsoft Edge|Brave|Mozilla Firefox|Firefox|Naver Whale|Whale|Opera|Vivaldi"
        if let regex = try? NSRegularExpression(pattern: " [-–—] (?:\(browsers))(?: [-–—] .*)?$") {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        return text.isEmpty ? nil : text
    }

    // MARK: 파일

    static func classifyFile(_ docPath: String, home: String, fileExists: (String) -> Bool) -> ClassifiedResource {
        let key = URINormalizer.normalize(filePath: docPath, home: home)
        let absolute = absolutePath(fromKey: key, home: home)
        let name = (absolute as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()

        if ext == "pdf", let arxiv = URINormalizer.arxivID(inFileName: name) {
            return ClassifiedResource(key: "arxiv:\(arxiv)", subtype: "Paper", title: name)
        }
        if codeExtensions.contains(ext) {
            let root = projectRoot(forFile: absolute, home: home, fileExists: fileExists)
            return ClassifiedResource(key: key, subtype: "CodeFile", title: name,
                                      projectKey: root.map { URINormalizer.normalize(filePath: $0, home: home) },
                                      projectTitle: root.map { ($0 as NSString).lastPathComponent })
        }
        if noteExtensions.contains(ext) { return ClassifiedResource(key: key, subtype: "Note", title: name) }
        if designExtensions.contains(ext) { return ClassifiedResource(key: key, subtype: "Design", title: name) }
        return ClassifiedResource(key: key, subtype: "Document", title: name)
    }

    static func absolutePath(fromKey key: String, home: String) -> String {
        var path = String(key.dropFirst("file:".count))
        if path.hasPrefix("~") { path = (home as NSString).standardizingPath + String(path.dropFirst(1)) }
        return path
    }

    /// 파일에서 위로 올라가며 .git, package.json 같은 표식이 있는 첫 폴더를 프로젝트 루트로 본다.
    static func projectRoot(forFile path: String, home: String, fileExists: (String) -> Bool) -> String? {
        let homeStd = (home as NSString).standardizingPath
        var dir = (path as NSString).deletingLastPathComponent
        var steps = 0
        while dir.count > 1, dir != homeStd, steps < 12 {
            for marker in projectMarkers where fileExists((dir as NSString).appendingPathComponent(marker)) {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
            steps += 1
        }
        return nil
    }

    // MARK: 에디터 창 제목

    public static func isEditor(bundle: String, name: String) -> Bool {
        if editorBundlePrefixes.contains(where: { bundle.hasPrefix($0) }) { return true }
        let lower = name.lowercased()
        return editorNameHints.contains { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasSuffix(" " + $0) }
    }

    /// "● TaskCard.tsx — dashboard", "dashboard – TaskCard.tsx", "WorkGraph — App.swift" 모두 처리.
    static func parseEditorTitle(_ title: String?, appName: String) -> (file: String, workspace: String?)? {
        guard let title, !title.isEmpty else { return nil }
        var normalized = title
        for sep in [" — ", " – ", " - "] { normalized = normalized.replacingOccurrences(of: sep, with: "\u{1F}") }
        let segments = normalized.split(separator: "\u{1F}").map { segment -> String in
            var s = segment.trimmingCharacters(in: .whitespaces)
            for prefix in ["● ", "• ", "* ", "◆ "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
            for suffix in [" ●", " •", " (Working Tree)", " (Index)"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
            return s
        }
        let known = codeExtensions.union(noteExtensions)
        guard let fileIndex = segments.firstIndex(where: { segment in
            let ext = (segment as NSString).pathExtension.lowercased()
            return !ext.isEmpty && known.contains(ext) && !segment.contains("/")
        }) else { return nil }
        let appLower = appName.lowercased()
        let workspace = segments.enumerated().first { index, segment in
            index != fileIndex && !segment.isEmpty && segment.lowercased() != appLower
                && !editorNameHints.contains(segment.lowercased())
        }?.element
        return (segments[fileIndex], workspace)
    }
}
