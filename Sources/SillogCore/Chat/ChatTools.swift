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
                Self.spec("search_context", "허용된 업무·대화·결과물·녹음의 전체 기록을 검색한다. 프로젝트 전용 기록은 소속 밖에서 읽지 않는다. 현재 프로젝트의 대화를 우선한다.", ["query": "핵심 검색어. 빈 문자열은 최근 기록", "from": "시작일 YYYY-MM-DD, 제한 없으면 빈 문자열", "to": "종료일 YYYY-MM-DD, 제한 없으면 빈 문자열"]),
                Self.spec("read_context", "검색한 원문을 이어 읽는다. 긴 대화는 메시지 ID로 원문을 읽는다.", ["id": "검색 결과의 id", "start": "대화는 시작 메시지 번호, 메시지·녹음은 시작 문자 위치. 처음이면 1"]),
                Self.spec("summarize_period", "기간의 업무별 작업 시간, 많이 쓴 자료, 앱 분포, 문제·할 일 변화를 사용 시간 기록으로 계산한다. 원문이 정리된 기간도 같은 수치를 돌려준다. 기간 시간·건수는 이 도구로 계산한다.", ["from": "시작일 YYYY-MM-DD", "to": "종료일 YYYY-MM-DD (포함)", "task": "업무 key 또는 제목 일부. 전체면 빈 문자열"]),
            ]
        }
        if !scope.libraryIDs.isEmpty || scope.useActivity || scope.projectID != nil {
            tools += [
                Self.spec("search_library", "이 대화의 첨부와 기억 범위에서 허용된 프로젝트 자료·이전 결과물을 검색한다. 다른 대화의 전용 첨부는 읽지 않는다.", ["query": "핵심 검색어. 빈 문자열은 자료 목록"]),
                Self.spec("read_library", "연결한 보관 자료의 추출된 원문을 이어 읽는다.", ["id": "검색 결과의 library ID", "start": "시작 문자 위치. 처음이면 1"]),
            ]
        }
        if !scope.paths.isEmpty {
            tools += [
                Self.spec("list_files", "연결한 폴더 내 파일을 찾는다. 숨김·빌드·의존성 폴더는 제외한다. 최대 100개를 반환한다.", ["path": "연결한 폴더 또는 그 하위 폴더. 빈 문자열은 연결 목록", "query": "파일 경로 검색어, 전체 목록이면 빈 문자열"]),
                Self.spec("read_file", "연결 범위 안의 텍스트 또는 PDF 원문을 읽는다. 비밀 키 파일은 읽지 않는다.", ["path": "파일 절대 경로", "start": "시작 줄 번호 또는 PDF 페이지 번호, 1부터"]),
                Self.spec("inspect_repository", "연결 범위 내 Git 저장소의 최근 커밋과 변경 파일 목록을 확인한다. 사용자 기여는 이름 추측 없이 커밋·PR로 확인한다.", ["path": "저장소 루트 절대 경로"]),
                Self.spec("read_revision", "특정 커밋의 파일 내용을 읽는다. 현재 파일과 과거 구현을 비교할 때 사용한다.", ["path": "저장소 루트", "commit": "전체 커밋 SHA", "file": "저장소 기준 파일 경로"]),
            ]
        }
        if scope.useGitHub {
            tools.append(Self.spec("github_search", "연결된 GitHub 계정의 저장소를 이름과 설명으로 찾는다.", ["query": "저장소 이름 또는 설명 검색어. 전체 목록이면 빈 문자열"]))
            tools.append(Self.spec("github_read", "GitHub 커넥터에서 저장소·PR·코드 파일을 읽는다.", ["repository": "owner/repository", "path": "저장소 안 파일 경로. 빈 문자열이면 저장소와 최근 PR 목록", "pull": "PR 번호. 파일을 읽을 때는 빈 문자열"]))
            tools.append(Self.spec("github_list", "GitHub 커넥터에서 저장소 루트 또는 하위 폴더의 파일 목록을 확인한다.", ["repository": "owner/repository", "path": "폴더 경로. 빈 문자열이면 저장소 루트"]))
        }
        if scope.connectors.contains("drive") {
            tools.append(Self.spec("drive_search", "Google Drive 커넥터에서 사용자가 SILLOG에 고른 파일만 이름으로 검색한다. 찾는 파일이 없으면 커넥터 화면의 'Drive 파일 고르기'로 추가하라고 안내한다.", ["query": "파일 이름 검색어. 고른 파일 전체면 빈 문자열"]))
            tools.append(Self.spec("drive_read", "Google Drive 커넥터에서 텍스트 또는 Google 문서의 내용을 읽는다.", ["id": "파일 ID"]))
        }
        if scope.connectors.contains("notion") && !remoteConnectors.contains("notion") {
            tools.append(Self.spec("notion_search", "Notion 커넥터에서 페이지 제목을 검색한다.", ["query": "페이지 제목 검색어"]))
            tools.append(Self.spec("notion_read", "Notion 커넥터에서 페이지의 블록 내용을 읽는다.", ["id": "페이지 ID"]))
        }
        for connector in RemoteReadConnector.allCases where scope.connectors.contains(connector.rawValue) && remoteConnectors.contains(connector.rawValue) {
            tools += connector.specs
        }
        for connector in ExternalReadConnector.allCases where scope.connectors.contains(connector.id) && !remoteConnectors.contains(connector.id) {
            tools += connector.specs
        }
        if scope.useWeb {
            tools += [
                Self.spec("web_search", "웹에서 자료를 검색한다. 사적인 대화·전체 기록·비밀 값은 검색어에 넣지 않는다.", ["query": "공개해도 되는 주제 중심 검색어"]),
                Self.spec("web_read", "공개 웹 페이지의 본문을 읽는다.", ["url": "검색되었거나 사용자가 제공한 HTTPS URL"]),
            ]
        }
        return tools
    }

    /// Args: call은 모델이 요청한 도구 이름과 JSON 인자이다.
    /// Returns: 도구 결과 텍스트와 출처 목록.
    /// Raises: 허용하지 않은 도구·경로, 잘못된 인자, 파일·DB·네트워크 오류.
    func execute(_ call: ChatToolCall) async throws -> ChatToolOutput {
        guard specs.contains(where: { $0.name == call.name }) else { throw ChatToolError.unavailable("허용하지 않은 도구입니다: \(call.name)") }
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
            guard from < to else { throw ChatToolError.unavailable("시작일이 종료일보다 늦습니다.") }
            return try Self.output(search.summarize(from: from, to: to, task: args["task"]))
        case "search_library": return try Self.output(library.search(args["query"] ?? "", ids: currentLibraryIDs()))
        case "read_library": return try Self.output([library.read(args["id"] ?? "", ids: currentLibraryIDs(), start: Int(args["start"] ?? "1") ?? 1)])
        case "list_files": return .init(text: try listFiles(path: args["path"] ?? "", query: args["query"] ?? ""))
        case "read_file": return try Self.output([readFile(path: args["path"] ?? "", start: Int(args["start"] ?? "1") ?? 1)])
        case "inspect_repository", "read_revision":
            let root = try allowedURL(args["path"] ?? "")
            let top = try await Self.git(root, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard try allowedURL(top).path == root.path else { throw ChatToolError.unavailable("연결 범위에 포함된 저장소 루트를 지정하세요.") }
            let body: String
            if call.name == "read_revision" {
                let commit = args["commit"] ?? "", file = args["file"] ?? ""
                guard (40...64).contains(commit.count), commit.allSatisfy(\.isHexDigit), !file.isEmpty, !file.hasPrefix("/") else { throw ChatToolError.unavailable("커밋 SHA와 상대 파일 경로가 필요합니다.") }
                let target = try allowedURL(root.appendingPathComponent(file).path)
                guard target.path.hasPrefix(root.path + "/") else { throw ChatToolError.unavailable("저장소 밖의 파일입니다.") }
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
                throw ChatToolError.unavailable("알 수 없는 도구입니다.")
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
            guard let file = try await driveSearch("", onlyReadable: true).sources.first else { return false }
            sources = try await driveRead(file.id).sources
        case "notion":
            guard let page = try await notionSearch("", onlyPages: true).sources.first else { return false }
            sources = try await notionRead(page.id).sources
        default:
            guard let connector = ExternalReadConnector(rawValue: id) else {
                throw ChatToolError.unavailable("알 수 없는 커넥터입니다.")
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
        guard allowed, !blocked else { throw ChatToolError.unavailable("연결한 자료 범위를 벗어나거나 인증 정보가 포함된 경로입니다.") }
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
        return paths.joined(separator: "\n") + "\n(최대 5,000개 항목 탐색 / 100개 반환. 없으면 검색 폴더를 좁히세요.)"
    }

    /// Args: path는 파일 경로, start는 시작 줄 또는 PDF 페이지이다.
    /// Returns: 줄 번호·페이지가 포함된 원문 출처.
    /// Raises: 접근 범위, 파일 크기·형식, 읽기 오류.
    private func readFile(path: String, start: Int) throws -> ChatSource {
        let url = try allowedURL(path), offset = max(1, start)
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? 0) <= 10_000_000 else { throw ChatToolError.unavailable("10MB 이하의 일반 파일만 읽을 수 있습니다.") }
        let content: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), offset <= pdf.pageCount else { throw ChatToolError.unavailable("PDF를 읽을 수 없거나 페이지 범위를 벗어났습니다.") }
            content = ((offset - 1)..<min(pdf.pageCount, offset + 4)).map { "[\($0 + 1)쪽]\n\(pdf.page(at: $0)?.string ?? "추출 가능한 텍스트 없음")" }.joined(separator: "\n")
        } else {
            guard (size.fileSize ?? 0) <= 1_000_000 else { throw ChatToolError.unavailable("텍스트 파일은 1MB 이하로 연결하세요.") }
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
            guard process.terminationStatus == 0 else { throw ChatToolError.unavailable("Git 자료를 읽지 못했습니다. 저장소 경로와 커밋을 확인하세요.") }
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
            throw ChatToolError.unavailable("웹 검색에는 공식 OpenAI API 채팅 연결과 API 키가 필요합니다. Codex 연결을 선택해도 웹 검색할 수 있습니다.")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("Bearer \(searchKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "model": .string(searchModel), "input": .string("다음 주제의 신뢰할 만한 웹 자료를 찾아 간단히 요약하세요. 검색어: \(query)"),
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
                    sources.append(.init(id: url, title: item["title"]?.stringValue ?? url, location: url, excerpt: "웹 검색 결과"))
                }
            }
        }
        let unique = Array(Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).prefix(10)
        return .init(text: "검색 요약:\n\(summary)\n출처:\n\(try Self.output(Array(unique)).text)", sources: Array(unique))
    }

    /// Args: repository는 owner/name, path는 코드 파일 경로, pull은 PR 번호 또는 빈 문자열이다.
    /// Returns: 저장소·PR·코드 파일 정보.
    /// Raises: 잘못된 저장소 식별자, 권한·HTTP·네트워크 오류.
    private func github(repository: String, path: String, pull: String) async throws -> ChatToolOutput {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }), pull.isEmpty || (Int(pull) ?? 0) > 0 else { throw ChatToolError.unavailable("저장소 이름 또는 PR 번호가 올바르지 않습니다.") }
        if !path.isEmpty {
            guard pull.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), path.count < 500 else { throw ChatToolError.unavailable("저장소의 상대 파일 경로가 필요합니다.") }
            let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/contents/\(encoded)")!)
            request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            let token = try await connectorToken("github")
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else { throw ChatToolError.unavailable("GitHub 파일을 읽지 못했습니다. 권한·경로·크기를 확인하세요.") }
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
            throw ChatToolError.unavailable("GitHub 저장소 또는 폴더 경로가 올바르지 않습니다.")
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
        guard !token.isEmpty else { throw ChatToolError.unavailable("GitHub 커넥터를 설정에서 연결하세요.") }
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
        guard (200..<300).contains(status) else { throw ChatToolError.unavailable("외부 서비스 HTTP \(status). API 키·권한·사용량을 확인하세요.") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 2_000_000 { throw ChatToolError.unavailable("외부 응답이 너무 큽니다.") }
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
            throw ChatToolError.unavailable("공개 HTTPS 웹 주소만 조회할 수 있습니다.")
        }
        return url
    }

    /// Args: value는 YYYY-MM-DD, fallback은 빈 값의 기본 시각이다.
    /// Returns: 현지 시간 기준 날짜의 Unix 시각.
    /// Raises: 유효하지 않은 날짜.
    private static func date(_ value: String, fallback: Double, endOfDay: Bool = false) throws -> Double {
        if value.isEmpty { return fallback }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: value) else { throw ChatToolError.unavailable("날짜는 YYYY-MM-DD로 입력하세요.") }
        return (endOfDay ? Calendar.current.date(byAdding: .day, value: 1, to: date)! : date).timeIntervalSince1970
    }

    /// Args: sources는 실제 조회에서 생성한 출처이다.
    /// Returns: 모델이 읽을 JSON과 UI에 표시할 동일한 출처.
    /// Raises: JSON 인코딩 오류.
    static func output(_ sources: [ChatSource]) throws -> ChatToolOutput {
        .init(text: String(decoding: try JSONEncoder().encode(sources), as: UTF8.self), sources: sources)
    }
}
