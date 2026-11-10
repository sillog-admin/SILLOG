import Foundation

/// 내려받은 파일을 어느 폴더에 둘지 제안한다. 파일마다 새로 판단한다:
///   파일 이름 + 받은 곳(URL) + 받을 당시 세션(보고 있던 창 제목·주소·화면 텍스트, 하던 업무)을
///   후보 폴더(색인에서 문맥으로 고른 상위 N개, 안에 든 파일 몇 개 포함)와 함께 LLM 에 주고 하나를 고르게 한다.
/// LLM 은 후보 밖의 경로를 만들 수 없고, 확신이 없으면 제안하지 않는다 (틀린 제안은 기능을 끄게 만든다).
/// 전에 수락·선택한 폴더는 규칙이 아니라 힌트로만 준다. 자동으로 옮기지 않는다. 사용자가 확인하면 옮기고, 되돌릴 수 있다.
public struct FolderSuggester: Sendable {
    public struct Context: Sendable {
        /// 무엇을 정리하는지: 내려받은 파일 또는 받아쓴 녹음
        public enum Kind: String, Sendable { case download, recording }

        public var recentTitles: [String]         // 받기 직전 10분 동안 본 창 제목·주소 (녹음은 녹음하는 동안 본 것)
        public var screenText: String?            // 받기 직전 화면의 텍스트 앞부분 (강의 사이트의 과목명·주차 등)
        public var openTasks: [TaskDigest]
        public var currentTaskKey: String?
        public var now: Double
        /// 파일 내용 발췌 (받아쓴 녹음: 요약 + 받아쓴 글 앞부분)
        public var contentExcerpt: String?
        public var kind: Kind
        public init(recentTitles: [String], screenText: String? = nil, openTasks: [TaskDigest], currentTaskKey: String? = nil, now: Double,
                    contentExcerpt: String? = nil, kind: Kind = .download) {
            self.recentTitles = recentTitles; self.screenText = screenText; self.openTasks = openTasks; self.currentTaskKey = currentTaskKey; self.now = now
            self.contentExcerpt = contentExcerpt; self.kind = kind
        }
    }

    let db: WGDatabase
    let store: FileSuggestionStore
    let llm: any LLMClient
    let home: String
    let minConfidence: Double
    let candidateLimit: Int

    public init(db: WGDatabase, llm: any LLMClient, home: String = NSHomeDirectory(), minConfidence: Double = 0.6, candidateLimit: Int = 25) {
        self.db = db; self.store = FileSuggestionStore(db); self.llm = llm; self.home = home
        self.minConfidence = minConfidence; self.candidateLimit = candidateLimit
    }

    // MARK: 제안

    public func suggest(filePath: String, originURL: String?, index: FolderIndex, context: Context) async throws -> FileSuggestion? {
        let fileName = (filePath as NSString).lastPathComponent
        guard !(try store.hasPending(path: filePath)), !(try store.recentlyUndone(path: filePath, since: context.now - 600)) else { return nil }
        let fileDir = (filePath as NSString).deletingLastPathComponent

        // 전에 배운 것은 힌트로만 (같은 페이지에서 받았어도 파일이 다르면 다른 폴더일 수 있다)
        var hints: [(String, String)] = []                  // (설명, 폴더)
        for key in Self.learningKeys(originURL: originURL, taskKey: context.currentTaskKey, fileName: fileName) {
            guard let folder = try store.learnedFolder(key: key), folder != fileDir, FileManager.default.fileExists(atPath: folder) else { continue }
            let what = key.hasPrefix("origin:") ? "a file from the same page" : key.hasPrefix("host:") ? "a file from the same site" : "a file downloaded while working on the same task"
            if !hints.contains(where: { $0.1 == folder }) { hints.append((what, folder)) }
        }

        var contextStrings = context.recentTitles
        contextStrings += context.openTasks.flatMap { [$0.title] + $0.topics }
        if let originURL { contextStrings.append(originURL) }
        if let screenText = context.screenText { contextStrings.append(String(screenText.prefix(300))) }
        if let excerpt = context.contentExcerpt { contextStrings.append(String(excerpt.prefix(300))) }   // 받아쓴 글의 과목·주제가 후보 순위에 들어간다
        var candidates = index.rank(fileName: fileName, context: contextStrings, limit: candidateLimit).filter { $0.path != fileDir }
        for (_, folder) in hints where !candidates.contains(where: { $0.path == folder }) {
            if let known = index.folders.first(where: { $0.path == folder }) { candidates.insert(known, at: 0) }
        }
        guard !candidates.isEmpty else { return nil }

        let prompt = Self.prompt(fileName: fileName, originURL: originURL, candidates: candidates, context: context, home: home, hints: hints)
        let result = try await llm.callFunction(system: Self.system(for: context.kind), user: prompt, tool: Self.tool)
        guard let object = try? JSONSerialization.jsonObject(with: result.arguments) as? [String: Any] else { return nil }
        let chosen = (object["folder"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0
        let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty, confidence >= minConfidence else { return nil }
        // 후보에 있는 실제 폴더만 받아들인다 (절대 경로 또는 ~ 표기 둘 다 허용)
        guard let folder = candidates.first(where: { $0.path == chosen || $0.relativePath == chosen || Self.expand(chosen, home: home) == $0.path }) else { return nil }

        let suggestion = FileSuggestion(ts: context.now, path: filePath, fileName: fileName, originUrl: originURL, suggestedFolder: folder.path,
                                        confidence: confidence, reason: reason, source: "llm", context: Self.encodeContext(context))
        return try store.insert(suggestion)
    }

    // MARK: 결정

    /// 제안대로 옮긴다. 돌려주는 값은 옮겨진 최종 경로.
    @discardableResult
    public func accept(id: Int64, now: Double) throws -> String {
        guard var suggestion = try store.suggestion(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let target = try move(from: suggestion.path, to: suggestion.suggestedFolder)
        suggestion.status = "moved"; suggestion.movedTo = target; suggestion.decidedAt = now
        try store.update(suggestion)
        try learn(from: suggestion, folder: suggestion.suggestedFolder, now: now)
        return target
    }

    /// 제안 대신 사용자가 고른 폴더로 옮긴다. 그 폴더가 정답 라벨이 된다.
    @discardableResult
    public func rejectAndMove(id: Int64, to folder: String, now: Double) throws -> String {
        guard var suggestion = try store.suggestion(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let target = try move(from: suggestion.path, to: folder)
        suggestion.status = "moved"; suggestion.movedTo = target; suggestion.decidedAt = now
        try store.update(suggestion)
        try learn(from: suggestion, folder: folder, now: now)
        return target
    }

    public func ignore(id: Int64, now: Double) throws {
        guard var suggestion = try store.suggestion(id: id) else { return }
        suggestion.status = "ignored"; suggestion.decidedAt = now
        try store.update(suggestion)
    }

    /// 옮긴 파일을 원래 자리로. 학습한 규칙도 지운다.
    @discardableResult
    public func undo(id: Int64, now: Double) throws -> String {
        guard var suggestion = try store.suggestion(id: id), let movedTo = suggestion.movedTo, suggestion.status == "moved" else { throw CocoaError(.fileNoSuchFile) }
        let restored = try move(from: movedTo, to: (suggestion.path as NSString).deletingLastPathComponent, preferredName: suggestion.fileName)
        suggestion.status = "undone"; suggestion.decidedAt = now
        try store.update(suggestion)
        let taskKey = suggestion.context.flatMap { Self.decodeContext($0)?.currentTaskKey }
        for key in Self.learningKeys(originURL: suggestion.originUrl, taskKey: taskKey, fileName: suggestion.fileName) { try store.forget(key: key) }
        return restored
    }

    /// 같은 이름이 있으면 "이름 (2).ext" 처럼 번호를 붙인다. 덮어쓰지 않는다.
    public func move(from source: String, to folder: String, preferredName: String? = nil) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let name = preferredName ?? (source as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = (folder as NSString).appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: target) {
            target = (folder as NSString).appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        try fm.moveItem(atPath: source, toPath: target)
        return target
    }

    private func learn(from suggestion: FileSuggestion, folder: String, now: Double) throws {
        let taskKey = suggestion.context.flatMap { Self.decodeContext($0)?.currentTaskKey }
        for key in Self.learningKeys(originURL: suggestion.originUrl, taskKey: taskKey, fileName: suggestion.fileName) {
            try store.learn(key: key, folder: folder, now: now)
        }
    }

    /// 학습 키: 출처 사이트+경로 앞부분(강의 사이트의 과목 페이지), 출처 사이트, 당시 업무
    static func learningKeys(originURL: String?, taskKey: String?, fileName: String) -> [String] {
        var keys: [String] = []
        if let originURL, let components = URLComponents(string: originURL), let host = components.host?.lowercased() {
            let segments = components.path.split(separator: "/").map(String.init)
            if segments.count >= 2 { keys.append("origin:\(host)/\(segments[0])/\(segments[1])") }     // /course/1234
            keys.append("host:\(host)")
        }
        if let taskKey { keys.append("task:\(taskKey)") }
        return keys
    }

    // MARK: LLM

    static let system = """
    You file a newly downloaded document into one of the user's existing folders.
    Judge each file on its own from three things: the file name, where it was downloaded from (URL), and what the user was looking at and working on when it arrived (window titles, page addresses, text on screen, recent tasks).
    CANDIDATES are real folders with a few of the files already inside. Pick the single best candidate: the folder that already holds files of the same course, project or kind, or that matches the course/project the user was working on. Use the most specific folder that fits, not a parent.
    Earlier choices, if given, are hints about the user's habits, not rules; a different kind of file from the same page may belong elsewhere.
    If no candidate clearly fits, return an empty folder with low confidence. Never invent a path: the folder must be copied exactly from CANDIDATES.
    Always answer by calling suggest_folder.
    """

    static let recordingSystem = """
    You file the transcript of a voice recording the user just made into one of the user's existing folders.
    Judge from what was said (CONTENT: the course, topic or project it is about), the file name, and what the user was looking at and working on while recording (window titles, recent tasks).
    CANDIDATES are real folders with a few of the files already inside. Pick the single best candidate: the folder of the same course, project or meeting series. Use the most specific folder that fits, not a parent.
    Earlier choices, if given, are hints about the user's habits, not rules.
    If no candidate clearly fits, return an empty folder with low confidence. Never invent a path: the folder must be copied exactly from CANDIDATES.
    Always answer by calling suggest_folder.
    """

    static func system(for kind: Context.Kind) -> String { kind == .recording ? recordingSystem : system }

    static var tool: ToolSpec {
        ToolSpec(name: "suggest_folder", description: "Choose the folder the file belongs in.", parameters: .object([
            "type": "object",
            "properties": .object([
                "folder": .object(["type": "string", "description": "exact path copied from CANDIDATES, or empty if none fits"]),
                "confidence": .object(["type": "number", "description": "0 to 1"]),
                "reason": .object(["type": "string", "description": "one short Korean sentence the user will see"]),
            ]),
            "required": .array(["folder", "confidence", "reason"]),
        ]))
    }

    static func prompt(fileName: String, originURL: String?, candidates: [FolderIndex.Folder], context: Context, home: String,
                       hints: [(String, String)] = []) -> String {
        var lines = ["FILE: \(fileName)"]
        if context.kind == .recording { lines.append("THIS FILE IS: the transcript of a voice recording the user just made") }
        if let originURL { lines.append("DOWNLOADED FROM: \(originURL)") }
        if let excerpt = context.contentExcerpt, !excerpt.isEmpty {
            let flat = String(excerpt.replacingOccurrences(of: "\n", with: " ").prefix(800))
            lines.append("CONTENT (transcript excerpt): \(flat)")
        }
        if !context.recentTitles.isEmpty {
            let label = context.kind == .recording ? "USER WAS LOOKING AT WHILE RECORDING: " : "USER WAS LOOKING AT: "
            lines.append(label + context.recentTitles.prefix(12).joined(separator: " | "))
        }
        if let screenText = context.screenText, !screenText.isEmpty { lines.append("TEXT ON SCREEN WHEN THE FILE ARRIVED: \(screenText.prefix(800))") }
        if !context.openTasks.isEmpty {
            lines.append("USER'S RECENT TASKS: " + context.openTasks.prefix(6).map { "\($0.title) (\($0.taskType ?? "-")\($0.topics.isEmpty ? "" : "; " + $0.topics.joined(separator: ", ")))" }.joined(separator: " | "))
        }
        for (what, folder) in hints { lines.append("EARLIER THE USER MOVED \(what) TO: \(Self.short(folder, home: home)) (hint, not a rule)") }
        lines.append("CANDIDATES (path — files inside):")
        for folder in candidates {
            let inside = folder.sampleFiles.isEmpty ? "(empty)" : folder.sampleFiles.prefix(5).joined(separator: ", ")
            lines.append("- \(folder.relativePath) — \(inside)\(folder.fileCount > 5 ? " (+\(folder.fileCount - 5))" : "")")
        }
        return lines.joined(separator: "\n")
    }

    static func short(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    public static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~") ? (home as NSString).standardizingPath + String(path.dropFirst(1)) : path
    }

    static func encodeContext(_ context: Context) -> String? {
        let object: [String: Any] = ["titles": Array(context.recentTitles.prefix(12)), "tasks": context.openTasks.prefix(6).map(\.title),
                                     "task": context.currentTaskKey ?? "", "kind": context.kind.rawValue]
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeContext(_ text: String) -> Context? {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let task = object["task"] as? String
        let kind = Context.Kind(rawValue: object["kind"] as? String ?? "") ?? .download
        return Context(recentTitles: object["titles"] as? [String] ?? [], openTasks: [], currentTaskKey: (task?.isEmpty ?? true) ? nil : task, now: 0, kind: kind)
    }
}
