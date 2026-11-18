import Foundation

/// 업무나 세션을 "다시 열기": 그때 만진 파일·프로젝트 폴더·웹페이지·앱을 모아 열 계획을 만든다.
/// 그래프의 세션 -TOUCHED-> 자료, 세션 -USED-> 앱, 자료 -BELONGS_TO-> 프로젝트 만으로 만들고, 실행(실제로 여는 것)은 앱 쪽이 한다.
/// 기본으로 켜는 것은 "마지막에 하던 것"뿐이다 (끝나기 전 10분 안에 만진 것, 최대 4개). 나머지는 목록에 남겨 골라 열 수 있다.
public struct ResumePlan: Equatable, Sendable {
    public enum Kind: String, Sendable { case folder, file, url, app }

    public struct Item: Identifiable, Equatable, Sendable {
        public var kind: Kind
        public var target: String            // 절대 경로 · URL · 앱 번들 id
        public var title: String
        public var appBundle: String?        // 어떤 앱으로 열지 (모르면 기본 앱)
        public var seconds: Double           // 그때 머문 시간
        public var lastAt: Double            // 마지막으로 만진 시각
        public var selected: Bool            // 기본으로 열지 (마지막에 하던 것만 true)
        public var id: String { kind.rawValue + ":" + target }
        public init(kind: Kind, target: String, title: String, appBundle: String? = nil, seconds: Double, lastAt: Double = 0, selected: Bool = false) {
            self.kind = kind; self.target = target; self.title = title; self.appBundle = appBundle; self.seconds = seconds; self.lastAt = lastAt; self.selected = selected
        }
    }

    public var title: String
    public var items: [Item]
    public var selectedItems: [Item] { items.filter(\.selected) }
    public init(title: String, items: [Item]) { self.title = title; self.items = items }
}

public enum ResumePlanner {
    /// 이 앱들은 "다시 열" 대상이 아니다 (우리 자신, 시스템, 파일 탐색기)
    public static let ignoredApps: Set<String> = ["com.sillog.app", "com.apple.finder", "com.apple.loginwindow", "com.apple.systempreferences",
                                                  "com.apple.UserNotificationCenter", "com.apple.ScreenSaver.Engine", "com.apple.Terminal", "excluded"]
    public static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "com.naver.Whale", "org.mozilla.firefox", "company.thebrowser.Browser",
                                               "com.microsoft.edgemac", "com.brave.Browser", "com.google.Chrome.canary"]
    /// 검색 결과·로그인·새로 만들기 같은 지나가는 페이지는 다시 열 대상이 아니다
    static func isTransient(url: String) -> Bool { TransientPages.isTransient(url: url, title: nil) }

    static let editors: Set<String> = ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.todesktop.230313mzl4w4u92"]

    public struct Options: Sendable {
        public var maxFiles = 6
        public var maxURLs = 6
        public var minFileSeconds = 20.0      // 잠깐 스친 파일은 뺀다
        public var minURLSeconds = 30.0       // 스쳐 지나간 페이지는 뺀다
        public var minAppSeconds = 60.0       // 자료 없이 앱만 오래 썼을 때만 앱을 연다
        public var recentSessions = 5         // 업무 단위로 열 때 합칠 최근 세션 수
        public var recentWindow = 600.0       // "마지막에 하던 것" = 마지막으로 만진 시각에서 이 시간 안에 만진 것
        public var maxDefaultItems = 4        // 기본으로 켜는 최대 개수 (폴더 제외)
        public init() {}
    }

    /// 세션 하나
    public static func plan(session: GraphNode, tx: GraphTx, home: String, fileExists: (String) -> Bool, options: Options = Options()) throws -> ResumePlan {
        try build(title: session.title, sessions: [session], tx: tx, home: home, fileExists: fileExists, options: options)
    }

    /// 업무 전체: 최근 세션 몇 개를 합친다 (오래 만진 것이 앞에)
    public static func plan(task: GraphNode, tx: GraphTx, home: String, fileExists: (String) -> Bool, options: Options = Options()) throws -> ResumePlan {
        let sessions = try tx.edges(to: task.id, type: EdgeType.partOf).compactMap { try tx.node(id: $0.src) }
            .sorted { ($0.props["start"]?.doubleValue ?? 0) > ($1.props["start"]?.doubleValue ?? 0) }
            .prefix(options.recentSessions)
        return try build(title: task.title, sessions: Array(sessions), tx: tx, home: home, fileExists: fileExists, options: options)
    }

    /// Args: sessions to merge; options sets the minimum seconds per kind.
    /// Returns: the plan; if nothing passes the minimums, it rebuilds once with every minimum at 0.
    /// Raises: database errors from tx.
    static func build(title: String, sessions: [GraphNode], tx: GraphTx, home: String, fileExists: (String) -> Bool, options: Options) throws -> ResumePlan {
        var fileSeconds: [String: (node: GraphNode, seconds: Double, lastAt: Double)] = [:]
        var urlSeconds: [String: (node: GraphNode, seconds: Double, lastAt: Double)] = [:]
        var appSeconds: [String: (title: String, seconds: Double, lastAt: Double)] = [:]
        var projectByFile: [String: String] = [:]
        var chatFolders: [String: Double] = [:]

        for session in sessions {
            for edge in try tx.edges(from: session.id, type: EdgeType.touched) {
                guard let resource = try tx.node(id: edge.dst) else { continue }
                if resource.key.hasPrefix("file:") {
                    let path = expand(String(resource.key.dropFirst("file:".count)), home: home)
                    guard fileExists(path) else { continue }
                    fileSeconds[path, default: (resource, 0, 0)].seconds += edge.weight
                    fileSeconds[path]!.lastAt = max(fileSeconds[path]!.lastAt, edge.lastAt)
                    if projectByFile[path] == nil { projectByFile[path] = try projectFolder(of: resource, tx: tx, home: home) }
                } else if resource.key.hasPrefix("chat:") {
                    // AI chat rows have no dwell; the folder the chat ran in is what to reopen.
                    // A chat run from the home directory records file:~, which is no project to reopen.
                    if let folder = try projectFolder(of: resource, tx: tx, home: home), folder != home {
                        chatFolders[folder] = max(chatFolders[folder] ?? 0, edge.lastAt)
                    }
                } else if let url = URINormalizer.openableURL(forKey: resource.key, home: home)?.absoluteString, !isTransient(url: url) {
                    urlSeconds[url, default: (resource, 0, 0)].seconds += edge.weight
                    urlSeconds[url]!.lastAt = max(urlSeconds[url]!.lastAt, edge.lastAt)
                }
            }
            for edge in try tx.edges(from: session.id, type: EdgeType.used) {
                guard let app = try tx.node(id: edge.dst), !ignoredApps.contains(app.key) else { continue }
                appSeconds[app.key, default: (app.title, 0, 0)].seconds += edge.weight
                appSeconds[app.key]!.lastAt = max(appSeconds[app.key]!.lastAt, edge.lastAt)
            }
        }

        var items: [ResumePlan.Item] = []
        let editor = appSeconds.filter { editors.contains($0.key) }.max { $0.value.seconds < $1.value.seconds }?.key
        let browser = appSeconds.filter { browsers.contains($0.key) }.max { $0.value.seconds < $1.value.seconds }?.key

        // 프로젝트 폴더 (코드 파일이 속한 저장소·폴더) — 편집기로 연다
        let files = fileSeconds.filter { $0.value.seconds >= options.minFileSeconds }.sorted { $0.value.seconds > $1.value.seconds }.prefix(options.maxFiles)
        var folders: [String: Double] = [:]
        for (path, entry) in files where entry.node.subtype == "CodeFile" {
            if let project = projectByFile[path], fileExists(project) { folders[project, default: 0] += entry.seconds }
        }
        for folder in chatFolders.keys where folders[folder] == nil && fileExists(folder) { folders[folder] = 0 }
        for (folder, seconds) in folders.sorted(by: { $0.value > $1.value }) {
            let lastAt = max(files.filter { projectByFile[$0.key] == folder }.map(\.value.lastAt).max() ?? 0, chatFolders[folder] ?? 0)
            items.append(.init(kind: .folder, target: folder, title: (folder as NSString).lastPathComponent, appBundle: editor, seconds: seconds, lastAt: lastAt))
        }
        for (path, entry) in files {
            let app = entry.node.subtype == "CodeFile" ? editor : nil          // 문서·이미지는 기본 앱으로
            items.append(.init(kind: .file, target: path, title: entry.node.title, appBundle: app, seconds: entry.seconds, lastAt: entry.lastAt))
        }
        for (url, entry) in urlSeconds.sorted(by: { $0.value.seconds > $1.value.seconds }).prefix(options.maxURLs) where entry.seconds >= options.minURLSeconds {
            items.append(.init(kind: .url, target: url, title: entry.node.title, appBundle: browser, seconds: entry.seconds, lastAt: entry.lastAt))
        }
        // 자료 없이 오래 쓴 앱 (메신저, 노트 앱 …). 편집기·브라우저는 위에서 파일·URL 로 열리면 뺀다
        let coveredApps = Set(items.compactMap(\.appBundle))
        for (bundle, entry) in appSeconds.sorted(by: { $0.value.seconds > $1.value.seconds })
        where entry.seconds >= options.minAppSeconds && !coveredApps.contains(bundle) {
            items.append(.init(kind: .app, target: bundle, title: entry.title, appBundle: bundle, seconds: entry.seconds, lastAt: entry.lastAt))
        }
        // Short work never reaches the minimums; offer its files, pages and apps instead of an empty sheet.
        if items.isEmpty, options.minFileSeconds > 0 || options.minURLSeconds > 0 || options.minAppSeconds > 0 {
            var all = options
            all.minFileSeconds = 0; all.minURLSeconds = 0; all.minAppSeconds = 0
            return try build(title: title, sessions: sessions, tx: tx, home: home, fileExists: fileExists, options: all)
        }
        return ResumePlan(title: title, items: markLastUsed(items, options: options))
    }

    /// Args: a resource node.
    /// Returns: the absolute folder of the `file:` project the resource BELONGS_TO, or nil.
    /// Raises: database errors from `tx`.
    static func projectFolder(of resource: GraphNode, tx: GraphTx, home: String) throws -> String? {
        guard let edge = try tx.edges(from: resource.id, type: EdgeType.belongsTo).first, let project = try tx.node(id: edge.dst),
              project.key.hasPrefix("file:") else { return nil }
        return expand(String(project.key.dropFirst("file:".count)), home: home)
    }

    /// Turns on files and pages touched within recentWindow of the latest one, newest first, up to maxDefaultItems, plus the folders of those files.
    /// Recent apps and folders are turned on only when no file or page is. Selected items come first, then newest.
    static func markLastUsed(_ items: [ResumePlan.Item], options: Options) -> [ResumePlan.Item] {
        var items = items
        let latest = items.filter { $0.kind != .folder }.map(\.lastAt).max() ?? 0
        var picked = 0
        for index in items.indices.sorted(by: { items[$0].lastAt > items[$1].lastAt }) where items[index].kind == .file || items[index].kind == .url {
            guard picked < options.maxDefaultItems, items[index].lastAt >= latest - options.recentWindow else { continue }
            items[index].selected = true
            picked += 1
        }
        if picked == 0 {
            for index in items.indices where items[index].kind == .app && items[index].lastAt >= latest - options.recentWindow { items[index].selected = true }
        }
        let selectedFiles = items.filter { $0.selected && $0.kind == .file }.map(\.target)
        let newest = items.map(\.lastAt).max() ?? 0          // chat folders may be all there is, so measure them against each other too
        for index in items.indices where items[index].kind == .folder {
            let alone = picked == 0 && items[index].lastAt >= newest - options.recentWindow     // an AI chat's folder, like apps above
            items[index].selected = alone || selectedFiles.contains { $0.hasPrefix(items[index].target + "/") }
        }
        return items.sorted { ($0.selected ? 1 : 0, $0.lastAt) > ($1.selected ? 1 : 0, $1.lastAt) }
    }

    static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~") ? home + path.dropFirst(1) : path
    }
}
