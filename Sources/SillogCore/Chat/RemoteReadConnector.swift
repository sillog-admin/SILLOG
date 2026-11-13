import Foundation

/// 공급자가 운영하는 MCP에 직접 연결한다. OAuth 권한과 별개로 실행할 읽기 도구를 제한한다.
public enum RemoteReadConnector: String, CaseIterable, Sendable {
    case notion, higgsfield, lovable, canva

    public var endpoint: URL {
        let value = switch self {
        case .notion: "https://mcp.notion.com/mcp"
        case .higgsfield: "https://mcp.higgsfield.ai/mcp"
        case .lovable: "https://mcp.lovable.dev"
        case .canva: "https://mcp.canva.com/mcp"
        }
        return URL(string: value)!
    }

    public var resource: String {
        self == .notion ? "https://mcp.notion.com" : endpoint.absoluteString
    }

    public var metadataURL: URL {
        let value = switch self {
        case .notion: "https://mcp.notion.com/.well-known/oauth-authorization-server"
        case .higgsfield: "https://clerk.higgsfield.ai/.well-known/oauth-authorization-server"
        case .lovable: "https://lovable.dev/.well-known/oauth-authorization-server/oauth"
        case .canva: "https://mcp.canva.com/.well-known/oauth-authorization-server"
        }
        return URL(string: value)!
    }

    public var scopes: String {
        switch self {
        case .notion: "default"
        case .higgsfield: "openid email offline_access"
        case .lovable: "offline projects:read workspaces:read"
        case .canva: "profile:read design:meta:read design:content:read folder:read comment:read"
        }
    }

    public func trustedAuthURL(_ value: String) throws -> URL {
        let hosts: Set<String> = switch self {
        case .notion: ["mcp.notion.com"]
        case .higgsfield: ["clerk.higgsfield.ai", "mcp.higgsfield.ai"]
        case .lovable: ["lovable.dev"]
        case .canva: ["mcp.canva.com"]
        }
        guard let url = URL(string: value), url.scheme == "https", let host = url.host,
              hosts.contains(host), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            throw ChatToolError.unavailable(tr("공급자의 인증 주소를 확인할 수 없습니다."))
        }
        return url
    }

    public var allowedTools: Set<String> {
        switch self {
        case .notion: ["notion-search", "notion-fetch"]
        case .higgsfield: ["show_generations", "show_generation_by_ids", "job_status"]
        case .lovable: ["list_workspaces", "list_projects", "get_project", "list_files", "read_file", "list_edits"]
        case .canva: ["search-designs", "get-design", "get-design-pages", "get-design-content", "get-presenter-notes",
                      "list-comments", "list-replies", "search-folders", "list-folder-items", "resolve-shortlink"]
        }
    }

    var specs: [ToolSpec] {
        [ChatTools.spec("\(rawValue)_tools", "\(rawValue)의 검색·읽기 도구와 인자 형식을 확인한다. 먼저 호출한 다음 허용된 도구만 사용한다.", [:]),
         ChatTools.spec("\(rawValue)_read", "\(rawValue)의 자료를 검색하거나 읽는다. tools에서 확인한 이름과 JSON 인자를 사용한다. 쓰기·생성·삭제는 실행할 수 없다.",
                        ["tool": "tools에서 받은 읽기 도구 이름", "arguments": "도구의 인자 JSON 객체 문자열. 비밀 값이나 대화 전체를 넣지 않는다."])]
    }
}

/// 인증 헤더가 다른 호스트로 따라가지 않도록 리다이렉트를 거절한다.
public final class ConnectorHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let session = URLSession(configuration: .ephemeral, delegate: ConnectorHTTP(), delegateQueue: nil)
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor RemoteReadSession {
    let connector: RemoteReadConnector
    let token: String
    private var sessionID: String?
    private var protocolVersion = "2025-06-18"
    private var initialized = false
    private let session: URLSession

    public init(_ connector: RemoteReadConnector, token: String, session: URLSession = ConnectorHTTP.session) {
        self.connector = connector; self.token = token; self.session = session
    }

    public func tools() async throws -> [[String: JSONValue]] {
        try await initialize()
        var tools: [[String: JSONValue]] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            let result = try await request("tools/list", params: cursor.map { ["cursor": .string($0)] } ?? [:])
            tools += (result["tools"]?.arrayValue ?? []).compactMap(\.objectValue)
            cursor = result["nextCursor"]?.stringValue
            guard tools.count < 500, cursor.map({ seenCursors.insert($0).inserted }) ?? true else {
                throw ChatToolError.unavailable(tr("커넥터 도구 목록을 끝까지 확인할 수 없습니다."))
            }
        } while cursor != nil
        return tools
    }

    public func readTools() async throws -> [[String: JSONValue]] {
        try await tools().filter { connector.allowedTools.contains($0["name"]?.stringValue ?? "") }
    }

    /// 로그인 여부와 별도로, 검색 결과에서 얻은 ID로 원문 읽기를 실행한다.
    public func checkSearchAndRead() async throws -> Bool {
        switch connector {
        case .notion:
            let found = try await call("notion-search", arguments: ["query": "", "query_type": "internal",
                "filters": .object(["created_by_user_ids": .array(["me"])])])
            let pages = Self.objects(found).filter { $0["id"]?.stringValue != nil && $0["url"]?.stringValue != nil }
            guard let id = pages.first?["id"]?.stringValue else { return false }
            let page = try await call("notion-fetch", arguments: ["id": .string(id)])
            return !Self.text(page).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .lovable:
            let workspaces = try await call("list_workspaces", arguments: [:])
            for workspace in Self.objects(workspaces) {
                guard let id = workspace["id"]?.stringValue else { continue }
                let found = try await call("list_projects", arguments: ["workspace_id": .string(id), "limit": 3])
                for project in Self.objects(found) {
                    guard let projectID = project["id"]?.stringValue else { continue }
                    let files = try await call("list_files", arguments: ["project_id": .string(projectID), "limit": 50])
                    let objects = Self.objects(files)
                    let paths = objects.compactMap { $0["path"]?.stringValue }
                    guard let path = paths.first(where: { $0.hasSuffix(".md") || $0.hasSuffix(".tsx") || $0.hasSuffix(".ts") }) else { continue }
                    let ref = objects.compactMap { $0["ref"]?.stringValue ?? $0["sha"]?.stringValue }.first ?? "HEAD"
                    let file = try await call("read_file", arguments: ["project_id": .string(projectID), "path": .string(path), "ref": .string(ref)])
                    return !Self.text(file).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            return false
        case .higgsfield:
            let found = try await call("show_generations", arguments: ["size": 1, "only_completed": false])
            let jobs = Self.objects(found).filter { $0["status"] != nil && $0["type"] != nil }
            guard let id = jobs.compactMap({ $0["id"]?.stringValue }).first else { return false }
            let job = try await call("job_status", arguments: ["jobId": .string(id)])
            return !Self.text(job).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .canva:
            let found = try await call("search-designs", arguments: ["limit": 3])
            for id in Self.objects(found).compactMap({ $0["id"]?.stringValue }) {
                let content = try await call("get-design-content", arguments: ["design_id": .string(id), "content_types": .array(["richtexts"])])
                if !Self.text(content).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            }
            return false
        }
    }

    private static func objects(_ result: [String: JSONValue]) -> [[String: JSONValue]] {
        func collect(_ value: JSONValue) -> [[String: JSONValue]] {
            switch value {
            case .object(let object): return [object] + object.values.flatMap(collect)
            case .array(let values): return values.flatMap(collect)
            case .string(let text):
                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), decoded != value else { return [] }
                return collect(decoded)
            default: return []
            }
        }
        return collect(.object(result))
    }

    public func call(_ name: String, arguments: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard connector.allowedTools.contains(name) else {
            throw ChatToolError.unavailable(tr("이 커넥터에서는 검색·읽기 도구만 실행할 수 있습니다: \(name)"))
        }
        try await initialize()
        let result = try await request("tools/call", params: ["name": .string(name), "arguments": .object(arguments)])
        guard result["isError"]?.boolValue != true else {
            throw ChatToolError.unavailable(String(Self.text(result).prefix(1500)))
        }
        return result
    }

    public static func text(_ result: [String: JSONValue]) -> String {
        let text = (result["content"]?.arrayValue ?? []).compactMap { block -> String? in
            guard block.objectValue?["type"]?.stringValue == "text" else { return nil }
            return block.objectValue?["text"]?.stringValue
        }.joined(separator: "\n")
        if !text.isEmpty { return text }
        return result["structuredContent"]?.objectValue.map(JSONValue.encodeObject) ?? ""
    }

    /// 자료 본문 속 임의 링크가 아니라 공급자가 반환한 문서 메타데이터만 출처로 사용한다.
    static func references(_ result: [String: JSONValue]) -> [(title: String, url: String)] {
        var roots = result["structuredContent"]?.objectValue.map { [$0] } ?? []
        for block in result["content"]?.arrayValue ?? [] {
            guard block.objectValue?["type"]?.stringValue == "text",
                  let text = block.objectValue?["text"]?.stringValue,
                  let object = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue else { continue }
            roots.append(object)
        }
        let documents = roots.flatMap { [$0] + ($0["results"]?.arrayValue ?? []).compactMap(\.objectValue) }
        var seen = Set<String>()
        return documents.compactMap { document in
            guard let title = document["title"]?.stringValue, !title.isEmpty,
                  let value = document["url"]?.stringValue, let url = URL(string: value),
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  seen.insert(value).inserted else { return nil }
            return (title, value)
        }
    }

    private func initialize() async throws {
        guard !initialized else { return }
        let result = try await request("initialize", params: [
            "protocolVersion": .string(protocolVersion), "capabilities": .object([:]),
            "clientInfo": .object(["name": "Sillog", "version": "1.0"])
        ])
        guard let version = result["protocolVersion"]?.stringValue,
              ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else {
            throw ChatToolError.unavailable(tr("지원하지 않는 커넥터 통신 버전입니다."))
        }
        protocolVersion = version
        _ = try await request("notifications/initialized", params: [:], notification: true)
        initialized = true
    }

    private func request(_ method: String, params: [String: JSONValue], notification: Bool = false) async throws -> [String: JSONValue] {
        let id = UUID().uuidString
        var body: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method), "params": .object(params)]
        if !notification { body["id"] = .string(id) }
        var request = URLRequest(url: connector.endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Sillog/1.0", forHTTPHeaderField: "User-Agent")
        if method != "initialize" { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ChatToolError.unavailable(status == 401 ? tr("\(connector.rawValue) 승인이 만료되었습니다. 다시 연결하세요.") : tr("\(connector.rawValue) 연결 HTTP \(status)"))
        }
        if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = value }
        if notification { return [:] }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            var event: [String] = []
            var lineBytes = Data()
            var size = 0
            // AsyncBytes.lines는 빈 줄을 생략하므로 SSE 이벤트 경계를 바이트 단위로 보존한다.
            for try await byte in bytes {
                size += 1
                guard size <= 4_000_000 else { throw ChatToolError.unavailable(tr("커넥터 응답이 너무 큽니다.")) }
                guard byte == 10 else { lineBytes.append(byte); continue }
                if lineBytes.last == 13 { lineBytes.removeLast() }
                let line = String(decoding: lineBytes, as: UTF8.self)
                lineBytes.removeAll(keepingCapacity: true)
                if line.isEmpty {
                    if let result = try Self.decodeReply(Data(event.joined(separator: "\n").utf8), id: id) { return result }
                    event = []
                } else if line.hasPrefix("data:") {
                    event.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }
            if let result = try Self.decodeReply(Data(event.joined(separator: "\n").utf8), id: id) { return result }
        } else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= 4_000_000 else { throw ChatToolError.unavailable(tr("커넥터 응답이 너무 큽니다.")) }
            }
            if let result = try Self.decodeReply(data, id: id) { return result }
        }
        throw ChatToolError.unavailable(tr("커넥터에서 요청에 맞는 응답을 받지 못했습니다."))
    }

    static func decodeReply(_ data: Data, id: String) throws -> [String: JSONValue]? {
        guard !data.isEmpty else { return nil }
        let reply = try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
        guard reply["id"]?.stringValue == id else { return nil }
        if let error = reply["error"]?.objectValue {
            throw ChatToolError.unavailable(String((error["message"]?.stringValue ?? tr("커넥터 요청 실패")).prefix(1500)))
        }
        guard let result = reply["result"]?.objectValue else { throw ChatToolError.unavailable(tr("커넥터 응답 형식이 올바르지 않습니다.")) }
        return result
    }
}
