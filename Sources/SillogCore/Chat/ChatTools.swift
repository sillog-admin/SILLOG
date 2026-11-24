import Foundation
import PDFKit

public enum ChatToolError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

struct ChatToolOutput: Sendable {
    var text: String
    var sources: [ChatSource] = []
}

/// 읽기 도구는 연결한 파일 범위와 네트워크 허용 여부를 실행 시점에 확인한다.
public struct ChatTools: Sendable {
    let search: ContextSearch
    let scope: ChatScope
    let library: LibraryStore
    let searchKey: String
    let searchModel: String
    let connectorToken: @Sendable (String) async throws -> String
    let connectorResource: @Sendable (String) throws -> String
    let remoteConnectors: Set<String>

    /// Args: db는 활동 DB, scope는 자료 범위, searchKey·searchModel은 OpenAI 검색 인증과 모델, connectorToken은 커넥터 OAuth 토큰 조회이다.
    /// Returns: 채팅 한 번에 사용할 읽기 도구 모음.
    /// Raises: 없음.
    public init(db: SillogDatabase, scope: ChatScope, searchKey: String = "", searchModel: String = "",
                connectorToken: @escaping @Sendable (String) async throws -> String = { _ in "" },
                connectorResource: @escaping @Sendable (String) throws -> String = { _ in "" },
                remoteConnectors: Set<String> = []) {
        search = ContextSearch(db, projectID: scope.projectID, focus: scope.focus, includeActivity: scope.useActivity)
        library = LibraryStore(db)
        self.scope = scope; self.searchKey = searchKey; self.searchModel = searchModel; self.connectorToken = connectorToken
        self.connectorResource = connectorResource
        self.remoteConnectors = remoteConnectors
    }

    /// Args: name·description은 도구 설명, fields는 문자열 인자 설명이다.
    /// Returns: 공통 JSON Schema를 사용하는 도구 정의.
    /// Raises: 없음.
    static func spec(_ name: String, _ description: String, _ fields: [String: String]) -> ToolSpec {
        ToolSpec(name: name, description: description, parameters: .object([
            "type": "object", "properties": .object(fields.mapValues { .object(["type": "string", "description": .string($0)]) }),
            "required": .array(fields.keys.sorted().map(JSONValue.string)), "additionalProperties": false,
        ]))
    }

    var specs: [ToolSpec] {
        var tools: [ToolSpec] = []
        if scope.useActivity || scope.projectID != nil {
            tools += [
                Self.spec("search_context", "Searches all permitted records of tasks, conversations, outputs and recordings. Project-only records are not read outside their project. Conversations in the current project come first.", ["query": "Key search terms. An empty string returns recent records", "from": "Start date YYYY-MM-DD, or an empty string for no limit", "to": "End date YYYY-MM-DD, or an empty string for no limit"]),
                Self.spec("read_context", "Continues reading the original text of a search result. For a long conversation, read the original text by message ID. For a node: id, returns the node and up to 24 of its most recently updated neighbors; read their node: ids to follow the work graph further.", ["id": "The id from a search result", "start": "For a conversation, the starting message number; for a message or recording, the starting character position. 1 to start from the beginning"]),
                Self.spec("summarize_period", "Calculates from the usage-time ledger the work time per task, the most-used materials, the app breakdown, and changes in problems and to-dos for a period. Periods whose original text has already been pruned still return the same figures. Compute time and counts for a period with this tool.", ["from": "Start date YYYY-MM-DD", "to": "End date YYYY-MM-DD (inclusive)", "task": "A task key or part of its title. An empty string for all"]),
            ]
        }
        if !scope.libraryIDs.isEmpty || scope.useActivity || scope.projectID != nil {
            tools += [
                Self.spec("search_library", "Searches this conversation's attachments and the project materials and previous outputs permitted by the memory scope. Attachments private to other conversations are not read.", ["query": "Key search terms. An empty string returns the list of materials"]),
                Self.spec("read_library", "Continues reading the extracted original text of a connected library item.", ["id": "The library ID from a search result", "start": "Starting character position. 1 to start from the beginning"]),
            ]
        }
        if !scope.paths.isEmpty {
            tools += [
                Self.spec("list_files", "Finds files in the connected folders. Hidden, build and dependency folders are excluded. Returns at most 100.", ["path": "A connected folder or one of its subfolders. An empty string returns the list of connected folders", "query": "Search term for file paths, or an empty string for the full list"]),
                Self.spec("read_file", "Reads the original text of a text or PDF file within the connected scope. Secret key files are not read.", ["path": "Absolute file path", "start": "Starting line number or PDF page number, from 1"]),
                Self.spec("inspect_repository", "Checks the recent commits and changed files of a Git repository within the connected scope. Confirm the user's contributions from commits and PRs, without guessing from names.", ["path": "Absolute path of the repository root"]),
                Self.spec("read_revision", "Reads a file's contents at a specific commit. Use it to compare the current file with a past implementation.", ["path": "Repository root", "commit": "Full commit SHA", "file": "File path relative to the repository"]),
            ]
        }
        if scope.useGitHub {
            tools.append(Self.spec("github_search", "Finds repositories of the connected GitHub account by name and description.", ["query": "Search term for repository names or descriptions. An empty string for the full list"]))
            tools.append(Self.spec("github_read", "Reads repositories, PRs and code files from the GitHub connector.", ["repository": "owner/repository", "path": "File path within the repository. An empty string returns the repository and its recent PRs", "pull": "PR number. An empty string when reading a file"]))
            tools.append(Self.spec("github_list", "Lists the files in a repository's root or a subfolder from the GitHub connector.", ["repository": "owner/repository", "path": "Folder path. An empty string for the repository root"]))
        }
        if scope.connectors.contains("drive") {
            // The menu label follows the app language so the model names what the user sees.
            tools.append(Self.spec("drive_search", "Searches by name the files the user picked for this conversation from the Google Drive connector. If the wanted file is not there, tell the user to add it with '\(tr("Google Drive에서 선택"))' in the + menu.", ["query": "Search term for file names. An empty string for all picked files"]))
            tools.append(Self.spec("drive_read", "Reads the contents of a text file or Google document picked for this conversation from the Google Drive connector.", ["id": "File ID"]))
        }
        if scope.connectors.contains("notion") && !remoteConnectors.contains("notion") {
            tools.append(Self.spec("notion_search", "Searches page titles in the Notion connector.", ["query": "Search term for page titles"]))
            tools.append(Self.spec("notion_read", "Reads a page's block contents from the Notion connector.", ["id": "Page ID"]))
        }
        for connector in RemoteReadConnector.allCases where scope.connectors.contains(connector.rawValue) && remoteConnectors.contains(connector.rawValue) {
            tools += connector.specs
        }
        for connector in ExternalReadConnector.allCases where scope.connectors.contains(connector.id) && !remoteConnectors.contains(connector.id) {
            tools += connector.specs
        }
        if scope.useWeb {
            tools += [
                Self.spec("web_search", "Searches the web for material. Do not put private conversations, whole records or secret values in the query.", ["query": "A topic-focused query that is safe to make public"]),
                Self.spec("web_read", "Reads the body text of a public web page.", ["url": "An HTTPS URL found by a search or given by the user"]),
            ]
        }
        return tools
    }

    /// Args: call은 모델이 요청한 도구 이름과 JSON 인자이다.
    /// Returns: 도구 결과 텍스트와 출처 목록.
    /// Raises: 허용하지 않은 도구·경로, 잘못된 인자, 파일·DB·네트워크 오류.
    func execute(_ call: ChatToolCall) async throws -> ChatToolOutput {
        guard specs.contains(where: { $0.name == call.name }) else { throw ChatToolError.unavailable(tr("허용하지 않은 도구입니다: \(call.name)")) }
        let args = try JSONDecoder().decode([String: String].self, from: Data(call.arguments.utf8))
        if let prefix = call.name.split(separator: "_").first, remoteConnectors.contains(String(prefix)),
           let connector = RemoteReadConnector(rawValue: String(prefix)) {
            let remote = RemoteReadSession(connector, token: try await connectorToken(connector.rawValue))
            if call.name == "\(connector.rawValue)_tools" {
                let tools = try await remote.readTools()
                return .init(text: JSONValue.encodeObject(["tools": .array(tools.map(JSONValue.object))]))
            }
            let arguments = try JSONDecoder().decode([String: JSONValue].self, from: Data((args["arguments"] ?? "{}").utf8))
            let result = try await remote.call(args["tool"] ?? "", arguments: arguments)
            let body = String(RemoteReadSession.text(result).prefix(24000))
            let sources = RemoteReadSession.references(result).map {
                ChatSource(id: "\(connector.rawValue):\($0.url)", title: $0.title, location: $0.url, excerpt: body)
            }
            return .init(text: body, sources: sources)
        }
        switch call.name {
        case "search_context":
            let from = try Self.date(args["from"] ?? "", fallback: 0)
            let to = try Self.date(args["to"] ?? "", fallback: Date().timeIntervalSince1970, endOfDay: true)
            return try Self.output(search.search(query: args["query"] ?? "", from: from, to: to))
        case "read_context": return try Self.output(search.read(args["id"] ?? "", start: Int(args["start"] ?? "1") ?? 1))
        case "summarize_period":
            let to = try Self.date(args["to"] ?? "", fallback: Date().timeIntervalSince1970, endOfDay: true)
            let from = try Self.date(args["from"] ?? "", fallback: to - 7 * 86_400)
            guard from < to else { throw ChatToolError.unavailable(tr("시작일이 종료일보다 늦습니다.")) }
            return try Self.output(search.summarize(from: from, to: to, task: args["task"]))
        case "search_library": return try Self.output(library.search(args["query"] ?? "", ids: currentLibraryIDs()))
        case "read_library": return try Self.output([library.read(args["id"] ?? "", ids: currentLibraryIDs(), start: Int(args["start"] ?? "1") ?? 1)])
        case "list_files": return .init(text: try listFiles(path: args["path"] ?? "", query: args["query"] ?? ""))
        case "read_file": return try Self.output([readFile(path: args["path"] ?? "", start: Int(args["start"] ?? "1") ?? 1)])
        case "inspect_repository", "read_revision":
            let root = try allowedURL(args["path"] ?? "")
            let top = try await Self.git(root, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard try allowedURL(top).path == root.path else { throw ChatToolError.unavailable(tr("연결 범위에 포함된 저장소 루트를 지정하세요.")) }
            let body: String
            if call.name == "read_revision" {
                let commit = args["commit"] ?? "", file = args["file"] ?? ""
                guard (40...64).contains(commit.count), commit.allSatisfy(\.isHexDigit), !file.isEmpty, !file.hasPrefix("/") else { throw ChatToolError.unavailable(tr("커밋 SHA와 상대 파일 경로가 필요합니다.")) }
                let target = try allowedURL(root.appendingPathComponent(file).path)
                guard target.path.hasPrefix(root.path + "/") else { throw ChatToolError.unavailable(tr("저장소 밖의 파일입니다.")) }
                body = try await Self.git(root, ["show", "\(commit):\(file)"])
            } else {
                body = try await Self.git(root, ["log", "-30", "--date=iso-strict", "--format=%H%n%an <%ae>%n%ad%n%s", "--stat", "--no-ext-diff", "--no-textconv"])
            }
            return try Self.output([.init(id: "git:\(root.path):\(args["commit"] ?? "history"):\(args["file"] ?? "")", title: "Git · \(root.lastPathComponent)", location: root.path, excerpt: body)])
        case "web_search":
            return try await openAISearch(String((args["query"] ?? "").prefix(400)))
        case "web_read":
            let url = try Self.webURL(args["url"] ?? "")
            return try await webRead(url)
        case "github_read": return try await github(repository: args["repository"] ?? "", path: args["path"] ?? "", pull: args["pull"] ?? "")
        case "github_search": return try await githubSearch(args["query"] ?? "")
        case "github_list": return try await githubList(repository: args["repository"] ?? "", path: args["path"] ?? "")
        case "drive_search": return try await driveSearch(args["query"] ?? "")
        case "drive_read": return try await driveRead(args["id"] ?? "")
        case "notion_search": return try await notionSearch(args["query"] ?? "")
        case "notion_read": return try await notionRead(args["id"] ?? "")
        default:
            guard let prefix = call.name.split(separator: "_").first,
                  let connector = ExternalReadConnector(rawValue: String(prefix)) else {
                throw ChatToolError.unavailable(tr("알 수 없는 도구입니다."))
            }
            return try await Self.output(connector.sources(query: args["query"] ?? "", reference: args["id"],
                                                        token: connectorToken(connector.id), resource: connectorResource(connector.id)))
        }
    }

    /// 연결한 서비스에서 자료 한 건을 검색하고 읽는다. 검사 결과만 반환한다.
    public func checkConnector(_ id: String) async throws -> Bool {
        if remoteConnectors.contains(id), let connector = RemoteReadConnector(rawValue: id) {
            return try await RemoteReadSession(connector, token: connectorToken(id)).checkSearchAndRead()
        }
        let sources: [ChatSource]
        switch id {
        case "github":
            guard let repository = try await githubSearch("").sources.first else { return false }
            sources = try await github(repository: repository.title, path: "", pull: "").sources
        case "drive":
            // drive.file sees nothing until a file is picked in a chat, so a successful empty list still proves the connection.
            guard let file = try await driveSearch("", onlyReadable: true).sources.first else { return true }
            sources = try await driveRead(file.id, anyPicked: true).sources
        case "notion":
            guard let page = try await notionSearch("", onlyPages: true).sources.first else { return false }
            sources = try await notionRead(page.id).sources
        default:
            guard let connector = ExternalReadConnector(rawValue: id) else {
                throw ChatToolError.unavailable(tr("알 수 없는 커넥터입니다."))
            }
            let token = try await connectorToken(id)
            let resource = try connectorResource(id)
            guard let result = try await connector.sources(token: token, resource: resource, limit: 1).first else { return false }
            if connector == .slack { sources = [result] }
            else { sources = try await connector.sources(reference: result.id, token: token, resource: resource) }
        }
        return sources.contains { !$0.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 중요한 저장 자료와 질문에 맞는 과거 기록을 첫 요청부터 제공한다. 원문 추가 조회는 도구로 이어간다.
    func rememberedSources(history: [ConversationMessage], sentIDs: [String]) throws -> [ChatSource] {
        let query = history.last(where: { $0.role == "user" })?.text ?? ""
        let recentIDs = Set(sentIDs.map { "message:\($0)" })
        let records = scope.useActivity || scope.projectID != nil ? try search.search(query: query).filter { !recentIDs.contains($0.id) } : []
        let ids = try currentLibraryIDs()
        let ownIDs = ids.filter { scope.libraryIDs.contains($0) }
        let notes = try library.search("", ids: ownIDs, notesOnly: true)
        let ownFiles = try library.search(query, ids: ownIDs)
        let files = try library.search(query, ids: ids)
        var seen: Set<String> = []
        return Array((notes + ownFiles + records.filter { $0.id.hasPrefix("message:") } + files + records.filter { !$0.id.hasPrefix("message:") })
            .filter { seen.insert($0.id).inserted }.prefix(12))
    }

    /// Args: since is the previous question's time; only images added to this conversation after it count, so text-only models
    ///   and old turns don't carry pictures. limit and maxBytes cap one request.
    /// Returns: image files, newest first. Larger or other formats stay on the OCR path through read_library.
    /// Raises: DB 오류.
    public func newImages(since: Double, limit: Int = 4, maxBytes: Int = 20_000_000) throws -> [URL] {
        guard let conversationID = scope.conversationID else { return [] }
        let ids = Set(try library.sourceIDs(conversationID: conversationID)).intersection(scope.libraryIDs)
        var total = 0
        return try library.items()
            .filter { ids.contains($0.id) && $0.createdAt > since && ChatModelMessage.imageTypes[URL(fileURLWithPath: $0.filename).pathExtension.lowercased()] != nil }
            .sorted { $0.createdAt > $1.createdAt }
            .map { library.url(for: $0) }
            .filter { url in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes - total else { return false }
                total += size; return true
            }
            .prefix(limit).map { $0 }
    }

    private func currentLibraryIDs() throws -> [String] {
        var ids = Set(scope.libraryIDs)
        if let conversationID = scope.conversationID {
            ids.formIntersection(try library.sourceIDs(conversationID: conversationID, projectID: scope.projectID))
        }
        if scope.useActivity || scope.projectID != nil { ids.formUnion(try search.projectSourceIDs()) }
        return Array(ids)
    }

    /// Args: path는 모델이 지정한 절대 경로이다.
    /// Returns: 연결한 범위 안에서 심볼릭 링크까지 해석한 URL.
    /// Raises: 연결 범위 밖 또는 인증 파일에 접근할 때 발생한다.
    func allowedURL(_ path: String) throws -> URL {
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let url = Self.resolve(requested)
        let allowed = scope.paths.contains { value in
            let root = Self.resolve(URL(fileURLWithPath: value).standardizedFileURL)
            var directory: ObjCBool = false
            FileManager.default.fileExists(atPath: root.path, isDirectory: &directory)
            return url.path == root.path || (directory.boolValue && url.path.hasPrefix(root.path + "/"))
        }
        let blocked = (requested.pathComponents + url.pathComponents).contains { Self.isPrivate($0) }
        guard allowed, !blocked else { throw ChatToolError.unavailable(tr("연결한 자료 범위를 벗어나거나 인증 정보가 포함된 경로입니다.")) }
        return url
    }

    /// Args: url은 절대 경로이다.
    /// Returns: 존재하지 않는 마지막 파일이 있어도 부모의 심볼릭 링크까지 해석한 경로.
    /// Raises: 없음. 실제 파일 읽기 오류는 호출부에서 전달한다.
    private static func resolve(_ url: URL) -> URL {
        url.pathComponents.dropFirst().reduce(URL(fileURLWithPath: "/", isDirectory: true)) {
            $0.appendingPathComponent($1).resolvingSymlinksInPath().standardizedFileURL
        }
    }

    /// Args: name은 경로 구성 요소이다.
    /// Returns: 인증 정보·비밀 키 경로이면 true.
    /// Raises: 없음.
    static func isPrivate(_ name: String) -> Bool {
        let value = name.lowercased()
        return [".git", ".ssh", ".aws", ".gnupg", ".codex", ".claude", ".config", ".docker", ".kube", ".netrc", ".npmrc", ".pypirc", ".git-credentials",
                "keychains", "auth.json", "codex-auth.json", "credentials", "credentials.json"].contains(value)
            || value == ".env" || value.hasPrefix(".env.") || value.hasPrefix("id_") || value.hasSuffix(".pem") || value.hasSuffix(".key") || value.hasSuffix(".p12")
    }

    /// Args: path는 검색 폴더, query는 경로에 포함될 검색어이다.
    /// Returns: 최대 100개 경로와 탐색 제한 안내.
    /// Raises: 허용 범위 밖 경로 또는 폴더 읽기 오류.
    private func listFiles(path: String, query: String) throws -> String {
        if path.isEmpty { return scope.paths.joined(separator: "\n") }
        let root = try allowedURL(path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) else { throw CocoaError(.fileReadNoSuchFile) }
        if !directory.boolValue { return root.path }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadNoPermission) }
        var paths: [String] = [], visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 5000 { break }
            if ["node_modules", "build", "dist", "vendor", "DerivedData"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard (try? allowedURL(url.path)) != nil else { enumerator.skipDescendants(); continue }
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { continue }
            if query.isEmpty || url.path.localizedCaseInsensitiveContains(query) { paths.append(url.path) }
            if paths.count >= 100 { break }
        }
        return paths.joined(separator: "\n") + "\n(Scans at most 5,000 entries / returns 100. If it is not here, narrow the search folder.)"
    }

    /// Args: path는 파일 경로, start는 시작 줄 또는 PDF 페이지이다.
    /// Returns: 줄 번호·페이지가 포함된 원문 출처.
    /// Raises: 접근 범위, 파일 크기·형식, 읽기 오류.
    private func readFile(path: String, start: Int) throws -> ChatSource {
        let url = try allowedURL(path), offset = max(1, start)
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? 0) <= 10_000_000 else { throw ChatToolError.unavailable(tr("10MB 이하의 일반 파일만 읽을 수 있습니다.")) }
        let content: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), offset <= pdf.pageCount else { throw ChatToolError.unavailable(tr("PDF를 읽을 수 없거나 페이지 범위를 벗어났습니다.")) }
            content = ((offset - 1)..<min(pdf.pageCount, offset + 4)).map { tr("[\($0 + 1)쪽]\n\(pdf.page(at: $0)?.string ?? tr("추출 가능한 텍스트 없음"))") }.joined(separator: "\n")
        } else {
            guard (size.fileSize ?? 0) <= 1_000_000 else { throw ChatToolError.unavailable(tr("텍스트 파일은 1MB 이하로 연결하세요.")) }
            let text = try String(contentsOf: url, encoding: .utf8)
            content = text.components(separatedBy: "\n").enumerated().dropFirst(offset - 1).prefix(250).map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        }
        return .init(id: "file:\(url.path):\(offset)", title: "\(url.lastPathComponent) · \(offset)부터", location: url.path, excerpt: String(content.prefix(20000)))
    }

    /// Args: root는 검증된 저장소, arguments는 코드가 구성한 읽기 전용 Git 인자이다.
    /// Returns: 최대 24,000바이트의 명령 출력.
    /// Raises: 실행 실패·시간 초과·취소·Git 오류. 재시도하지 않는다.
    private static func git(_ root: URL, _ arguments: [String]) async throws -> String {
        try Task.checkCancellation()
        let value = try await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--no-pager", "-c", "core.fsmonitor=false", "-C", root.path] + arguments
            process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            defer { timeout.cancel() }
            var output = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                if output.count < 24000 { output.append(chunk.prefix(24000 - output.count)) }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ChatToolError.unavailable(tr("Git 자료를 읽지 못했습니다. 저장소 경로와 커밋을 확인하세요.")) }
            return String(decoding: output, as: UTF8.self)
        }.value
        try Task.checkCancellation()
        return value
    }

    /// Args: query는 공개해도 되는 웹 검색어이다.
    /// Returns: OpenAI 웹 검색 요약과 원문 링크 출처.
    /// Raises: OpenAI API·네트워크·응답 오류.
    private func openAISearch(_ query: String) async throws -> ChatToolOutput {
        guard !searchKey.isEmpty, !searchModel.isEmpty else {
            throw ChatToolError.unavailable(tr("웹 검색에는 공식 OpenAI API 채팅 연결과 API 키가 필요합니다. Codex 연결을 선택해도 웹 검색할 수 있습니다."))
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("Bearer \(searchKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "model": .string(searchModel), "input": .string("Find reliable web sources on this topic and summarize them briefly in \(L10n.current.promptName). Query: \(query)"),
            "tools": .array([.object(["type": .string("web_search")])]),
            "tool_choice": .string("required"), "include": .array([.string("web_search_call.action.sources")]),
        ]))
        let response = try await Self.json(request).objectValue ?? [:]
        var summary = "", sources: [ChatSource] = []
        for item in response["output"]?.arrayValue ?? [] {
            let value = item.objectValue ?? [:]
            for content in value["content"]?.arrayValue ?? [] {
                let part = content.objectValue ?? [:]
                summary += part["text"]?.stringValue ?? ""
                for annotation in part["annotations"]?.arrayValue ?? [] {
                    let citation = annotation.objectValue ?? [:]
                    if let url = citation["url"]?.stringValue {
                        sources.append(.init(id: url, title: citation["title"]?.stringValue ?? url, location: url, excerpt: String(summary.prefix(1000))))
                    }
                }
            }
            for source in value["action"]?.objectValue?["sources"]?.arrayValue ?? [] {
                let item = source.objectValue ?? [:]
                if let url = item["url"]?.stringValue {
                    sources.append(.init(id: url, title: item["title"]?.stringValue ?? url, location: url, excerpt: tr("웹 검색 결과")))
                }
            }
        }
        let unique = Array(Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).prefix(10)
        return .init(text: "Search summary:\n\(summary)\nSources:\n\(try Self.output(Array(unique)).text)", sources: Array(unique))
    }

    /// Args: repository는 owner/name, path는 코드 파일 경로, pull은 PR 번호 또는 빈 문자열이다.
    /// Returns: 저장소·PR·코드 파일 정보.
    /// Raises: 잘못된 저장소 식별자, 권한·HTTP·네트워크 오류.
    private func github(repository: String, path: String, pull: String) async throws -> ChatToolOutput {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }), pull.isEmpty || (Int(pull) ?? 0) > 0 else { throw ChatToolError.unavailable(tr("저장소 이름 또는 PR 번호가 올바르지 않습니다.")) }
        if !path.isEmpty {
            guard pull.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), path.count < 500 else { throw ChatToolError.unavailable(tr("저장소의 상대 파일 경로가 필요합니다.")) }
            let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/contents/\(encoded)")!)
            request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            let token = try await connectorToken("github")
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else { throw ChatToolError.unavailable(tr("GitHub 파일을 읽지 못했습니다. 권한·경로·크기를 확인하세요.")) }
            let url = "https://github.com/\(repository)/blob/HEAD/\(encoded)"
            return try Self.output([.init(id: url, title: "GitHub · \(path)", location: url, excerpt: String(decoding: data.prefix(20000), as: UTF8.self))])
        }
        let paths = pull.isEmpty ? ["", "/pulls?state=all&per_page=10"] : ["/pulls/\(pull)", "/pulls/\(pull)/files?per_page=30"]
        var excerpts: [String] = []
        let token = try await connectorToken("github")
        for path in paths {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)\(path)")!)
            request.timeoutInterval = 30
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let json = try await Self.json(request)
            let items = json.arrayValue ?? [json]
            for item in items {
                let fields = item.objectValue ?? [:]
                var selected = fields.filter { ["full_name", "description", "html_url", "number", "title", "body", "state", "merged_at", "filename", "status", "additions", "deletions"].contains($0.key) }
                if let login = fields["user"]?.objectValue?["login"] { selected["author"] = login }
                excerpts.append(JSONValue.encodeObject(selected))
            }
        }
        let url = "https://github.com/\(repository)" + (pull.isEmpty ? "" : "/pull/\(pull)")
        return try Self.output([.init(id: url, title: "GitHub · \(repository)\(pull.isEmpty ? "" : " #\(pull)")", location: url, excerpt: String(excerpts.joined(separator: "\n").prefix(20000)))])
    }

    /// Args: repository는 owner/name, path는 저장소의 상대 폴더 경로이다.
    /// Returns: 파일 이름·형식·원문 링크를 포함한 폴더 목록.
    /// Raises: 잘못된 경로·GitHub API 오류.
    private func githubList(repository: String, path: String) async throws -> ChatToolOutput {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }),
              !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), path.count < 500 else {
            throw ChatToolError.unavailable(tr("GitHub 저장소 또는 폴더 경로가 올바르지 않습니다."))
        }
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/contents/\(encoded)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let token = try await connectorToken("github")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let items = try await Self.json(request).arrayValue ?? []
        let sources = items.prefix(100).compactMap { value -> ChatSource? in
            let item = value.objectValue ?? [:]
            guard let name = item["name"]?.stringValue, let fullPath = item["path"]?.stringValue else { return nil }
            let url = item["html_url"]?.stringValue ?? "https://github.com/\(repository)"
            return .init(id: url, title: name, location: url, excerpt: "\(item["type"]?.stringValue ?? "파일") · \(fullPath)")
        }
        return try Self.output(sources)
    }

    /// Args: query는 계정의 저장소 이름·설명 검색어이다.
    /// Returns: 최근 저장소 최대 100개 중 관련 저장소의 이름·설명·링크.
    /// Raises: GitHub 연결·API 오류.
    private func githubSearch(_ query: String) async throws -> ChatToolOutput {
        let token = try await connectorToken("github")
        guard !token.isEmpty else { throw ChatToolError.unavailable(tr("GitHub 커넥터를 설정에서 연결하세요.")) }
        var request = URLRequest(url: URL(string: "https://api.github.com/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let repositories = try await Self.json(request).arrayValue ?? []
        let sources = repositories.compactMap { item -> ChatSource? in
            let value = item.objectValue ?? [:]
            guard let name = value["full_name"]?.stringValue, let url = value["html_url"]?.stringValue else { return nil }
            let description = value["description"]?.stringValue ?? ""
            guard query.isEmpty || name.localizedCaseInsensitiveContains(query) || description.localizedCaseInsensitiveContains(query) else { return nil }
            return .init(id: url, title: name, location: url, excerpt: description)
        }
        return try Self.output(Array(sources.prefix(30)))
    }

    /// Args: request는 고정된 외부 API 주소에 보내는 요청이다.
    /// Returns: 2MB 이하의 JSON 값.
    /// Raises: HTTP 오류, 응답 크기 초과, 연결·디코딩 오류.
    static func json(_ request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> JSONValue {
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ChatToolError.unavailable(tr("외부 서비스 HTTP \(status). API 키·권한·사용량을 확인하세요.")) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 2_000_000 { throw ChatToolError.unavailable(tr("외부 응답이 너무 큽니다.")) }
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Args: value는 공개 웹 자료 주소이다.
    /// Returns: 인증 정보와 로컬 주소를 포함하지 않는 HTTPS URL.
    /// Raises: 잘못된 URL 또는 로컬 주소.
    static func webURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }), url.user == nil, url.password == nil else {
            throw ChatToolError.unavailable(tr("공개 HTTPS 웹 주소만 조회할 수 있습니다."))
        }
        return url
    }

    /// Args: value는 YYYY-MM-DD, fallback은 빈 값의 기본 시각이다.
    /// Returns: 현지 시간 기준 날짜의 Unix 시각.
    /// Raises: 유효하지 않은 날짜.
    static func date(_ value: String, fallback: Double, endOfDay: Bool = false) throws -> Double {
        if value.isEmpty { return fallback }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: value) else { throw ChatToolError.unavailable(tr("날짜는 YYYY-MM-DD로 입력하세요.")) }
        return (endOfDay ? Calendar.current.date(byAdding: .day, value: 1, to: date)! : date).timeIntervalSince1970
    }

    /// Args: sources는 실제 조회에서 생성한 출처이다.
    /// Returns: 모델이 읽을 JSON과 UI에 표시할 동일한 출처.
    /// Raises: JSON 인코딩 오류.
    static func output(_ sources: [ChatSource]) throws -> ChatToolOutput {
        .init(text: String(decoding: try JSONEncoder().encode(sources), as: UTF8.self), sources: sources)
    }
}
