import Foundation

/// Serves SILLOG records to MCP clients as newline-delimited JSON-RPC. Read-only, and project-only records stay hidden.
public struct MCPServer: Sendable {
    /// Result kinds a search can be narrowed to. Raw values are the id prefixes of the results.
    enum Kind: String, CaseIterable { case node, card, observation, digest, chat, recording, message, library, file }

    /// What list_items can list. Raw values are the tool's type argument.
    enum ItemType: String, CaseIterable {
        case task, session, problem, todo
        var label: String {
            switch self {
            case .task: NodeLabel.task
            case .session: NodeLabel.session
            case .problem: NodeLabel.problem
            case .todo: NodeLabel.laterItem
            }
        }
    }

    static let maxNodes = 60
    static let maxItems = 100
    static let maxSearch = 50
    let tools: ChatTools

    /// Args: db is the activity database.
    /// Returns: A server that reads activity records outside project-only projects.
    /// Raises: nothing.
    public init(db: SillogDatabase) { tools = ChatTools(db: db, scope: ChatScope()) }

    static func field(_ description: String, type: String = "string", options: [String] = []) -> JSONValue {
        var field: [String: JSONValue] = ["type": .string(type), "description": .string(description)]
        if !options.isEmpty { field["enum"] = .array(options.map(JSONValue.string)) }
        return .object(field)
    }

    static func spec(_ name: String, _ description: String, required: [String], _ fields: [String: JSONValue]) -> ToolSpec {
        ToolSpec(name: name, description: description, parameters: .object([
            "type": "object", "properties": .object(fields), "required": .array(required.map(JSONValue.string)),
        ]))
    }

    static let specs: [ToolSpec] = [
        spec("search", "사용자의 SILLOG 기록(업무 그래프, 화면 요약, 화면 원문, AI 도구에 보낸 요청, 녹음, 주간·월간 요약, SILLOG 채팅, 보관함 자료, 파일)을 검색한다. 종류를 정하지 않으면 종류마다 최근 몇 개씩, kind를 정하면 그 종류만 50개까지 준다. 결과의 id를 fetch나 get_related에 넘긴다.", required: ["query"], [
            "query": field("기록에 그대로 나올 단어 하나나 짧은 구절. 여러 단어를 나열하면 그 구절 전체가 있어야 찾으므로 한 번에 하나씩 검색한다. 빈 문자열은 최근 기록"),
            "from": field("시작일 YYYY-MM-DD. 제한 없으면 생략"),
            "to": field("종료일 YYYY-MM-DD. 제한 없으면 생략"),
            "kind": field("한 종류만 볼 때: node(업무·자료 그래프), card(화면 요약), observation(화면 원문), digest(주간·월간 요약), chat(AI 도구에 보낸 요청), recording(녹음), message(SILLOG 채팅), library(SILLOG 보관함에 올린 자료와 저장한 결과물), file(새로 생기거나 내려받은 파일의 경로. 이 종류는 지정해야만 찾는다)", options: Kind.allCases.map(\.rawValue)),
        ]),
        spec("fetch", "검색 결과의 원문을 읽는다. 긴 글은 응답 끝에 적힌 다음 시작 위치로 이어 읽는다.", required: ["id"], [
            "id": field("검색 결과의 id. SILLOG 채팅 결과에 적힌 conversation:<id>로 대화 전체를 읽는다"),
            "start": field("대화는 시작 메시지 번호, 메시지·녹음은 시작 문자 위치. 처음이면 1", type: "integer"),
        ]),
        spec("summarize_period", "기간의 업무별 작업 시간, 많이 쓴 자료, 앱 분포, 문제·할 일 변화를 사용 시간 기록으로 계산한다. 시간과 건수는 검색 결과로 어림하지 말고 이 도구로 구한다. 그 기간에 한 일을 글로 정리한 것은 search의 kind=digest로 찾는다.", required: ["from", "to"], [
            "from": field("시작일 YYYY-MM-DD"),
            "to": field("종료일 YYYY-MM-DD (포함)"),
            "task": field("업무 key, 업무 제목 일부, 또는 프로젝트 이름. 전체면 생략"),
        ]),
        spec("list_items", "기간 안의 업무, 세션, 문제, 할 일을 종류별로 시간순으로 나열한다. 100개가 넘으면 최근 100개만 주고 끝에 알린다. 하루를 시간순으로 정리하거나 막힌 문제·미뤄 둔 할 일을 볼 때는 검색 대신 이 도구를 쓴다.", required: ["type"], [
            "type": field("task(업무), session(업무를 한 시간 구간과 한 일 요약), problem(막힌 문제와 해결 여부), todo(나중에 하기로 한 일)", options: ItemType.allCases.map(\.rawValue)),
            "from": field("시작일 YYYY-MM-DD. 제한 없으면 생략"),
            "to": field("종료일 YYYY-MM-DD (포함). 제한 없으면 생략"),
        ]),
        spec("get_related", "업무 그래프에서 한 노드와 이어진 세션, 자료, 앱, 주제, 문제, 할 일을 따라간다.", required: ["id"], [
            "id": field("검색 결과 중 node:로 시작하는 id"),
            "hops": field("몇 단계까지 따라갈지. 1 또는 2, 기본 1", type: "integer"),
        ]),
    ]

    /// Args: line is one JSON-RPC message.
    /// Returns: The response line, or nil when the message is a notification.
    /// Raises: nothing. Failures become JSON-RPC errors or tool results with isError.
    public func handle(_ line: String) async -> String? {
        guard let message = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)) else {
            return Self.reply(.null, error: -32700, "Parse error")
        }
        guard let id = message["id"], id != .null else { return nil }
        let params = message["params"]?.objectValue ?? [:]
        switch message["method"]?.stringValue {
        case "initialize":
            // Echoing the client's version is safe: only the tools basics are used, and those are the same in every revision.
            return Self.reply(id, result: [
                "protocolVersion": params["protocolVersion"] ?? "2025-06-18",
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": "sillog", "version": "1"]),
            ])
        case "ping":
            return Self.reply(id, result: [:])
        case "tools/list":
            return Self.reply(id, result: ["tools": .array(Self.specs.map {
                // Clients ask for approval on every call unless a tool says it only reads.
                .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.parameters,
                         "annotations": .object(["readOnlyHint": true])])
            })])
        case "tools/call":
            var text: String, failed = false
            do { text = try await call(params["name"]?.stringValue ?? "", params["arguments"]?.objectValue ?? [:]) }
            catch { text = error.localizedDescription; failed = true }
            return Self.reply(id, result: [
                "content": .array([.object(["type": "text", "text": .string(PIIMasker.mask(text))])]),
                "isError": .bool(failed),
            ])
        default:
            return Self.reply(id, error: -32601, "Method not found")
        }
    }

    /// Args: name is the MCP tool name, args are its JSON arguments.
    /// Returns: The tool result as text.
    /// Raises: ChatToolError for an unknown tool or a bad date, and DB read errors.
    func call(_ name: String, _ args: [String: JSONValue]) async throws -> String {
        func text(_ key: String, _ fallback: String = "") -> String {
            switch args[key] {
            case .string(let value): return value
            // Int(Double) traps on huge or non-finite numbers, which would kill the server.
            case .number(let value): return Int(exactly: value.rounded()).map(String.init) ?? fallback
            default: return fallback
            }
        }
        func run(_ tool: String, _ arguments: [String: String]) async throws -> ChatToolOutput {
            try await tools.execute(ChatToolCall(id: "", name: tool, arguments: JSONValue.encodeObject(arguments.mapValues(JSONValue.string))))
        }
        switch name {
        case "search":
            let kind = Kind(rawValue: text("kind"))
            guard kind != nil || text("kind").isEmpty else { throw ChatToolError.unavailable(tr("kind는 \(Kind.allCases.map(\.rawValue).joined(separator: ", ")) 중 하나로 지정하세요.")) }
            let from = try ChatTools.date(text("from"), fallback: 0)
            let to = try ChatTools.date(text("to"), fallback: Date().timeIntervalSince1970, endOfDay: true)
            // One extra row tells whether more were left out.
            var found = kind == .library ? [] : try tools.search.search(query: text("query"), from: from, to: to, kind: kind?.rawValue, limit: Self.maxSearch + 1)
            // shortcut: library search ignores the period and stops at 8 items, fine while the library stays small.
            if kind == nil || kind == .library { found += try tools.library.search(text("query"), ids: tools.search.openLibraryIDs()) }
            let note = kind != nil && found.count > Self.maxSearch ? "\n[\(Self.maxSearch)개까지만 보여 줬어요. 기간을 좁혀 다시 검색하세요.]" : ""
            return try ChatTools.output(withConversation(Array(found.prefix(kind == nil ? found.count : Self.maxSearch)))).text + note
        case "fetch":
            if text("id").hasPrefix("library:") {
                return try ChatTools.output([tools.library.read(text("id"), ids: tools.search.openLibraryIDs(), start: Int(text("start", "1")) ?? 1)]).text
            }
            return try ChatTools.output(withConversation(tools.search.read(text("id"), start: Int(text("start", "1")) ?? 1))).text
        case "summarize_period":
            return try await run("summarize_period", ["from": text("from"), "to": text("to"), "task": text("task")]).text
        case "list_items":
            guard let type = ItemType(rawValue: text("type")) else {
                throw ChatToolError.unavailable(tr("type은 \(ItemType.allCases.map(\.rawValue).joined(separator: ", ")) 중 하나로 지정하세요."))
            }
            let from = try ChatTools.date(text("from"), fallback: 0)
            let to = try ChatTools.date(text("to"), fallback: Date().timeIntervalSince1970, endOfDay: true)
            // One extra row tells whether older items were left out.
            let items = try tools.search.nodes(label: type.label, from: from, to: to, limit: Self.maxItems + 1)
            let note = items.count > Self.maxItems ? "\n[최근 \(Self.maxItems)개만 보여 줬어요. 더 이른 항목은 to를 앞당겨 보세요.]" : ""
            return try ChatTools.output(Array(items.suffix(Self.maxItems))).text + note
        case "get_related":
            return Self.describe(try tools.search.related(text("id"), hops: Int(text("hops", "1")) ?? 1))
        default:
            throw ChatToolError.unavailable(tr("알 수 없는 도구입니다."))
        }
    }

    /// The app's source cards show excerpts as they are, so only MCP output gets the conversation line.
    func withConversation(_ sources: [ChatSource]) throws -> [ChatSource] {
        func messageID(_ source: ChatSource) -> String? {
            let pieces = source.id.split(separator: ":")
            return pieces.count >= 2 && pieces[0] == "message" ? String(pieces[1]) : nil
        }
        let headers = try tools.search.messageHeaders(sources.compactMap(messageID))
        return sources.map { source in
            var source = source
            if let header = messageID(source).flatMap({ headers[$0] }) { source.excerpt = header + source.excerpt }
            return source
        }
    }

    static func describe(_ graph: Subgraph) -> String {
        let nodes = graph.nodes.prefix(maxNodes), shown = Set(nodes.map(\.id))
        var lines = nodes.map { "node:\($0.id) | \($0.label) | \($0.title) | \($0.key)" }
        lines += graph.edges.filter { shown.contains($0.src) && shown.contains($0.dst) }.map { "node:\($0.src) -[\($0.type)]-> node:\($0.dst)" }
        if graph.nodes.count > maxNodes { lines.append("[전체 \(graph.nodes.count)개 중 최근 \(maxNodes)개만 표시]") }
        return lines.isEmpty ? "[]" : lines.joined(separator: "\n")
    }

    static func reply(_ id: JSONValue, result: [String: JSONValue]) -> String {
        JSONValue.encodeObject(["jsonrpc": "2.0", "id": id, "result": .object(result)])
    }

    static func reply(_ id: JSONValue, error code: Int, _ message: String) -> String {
        JSONValue.encodeObject(["jsonrpc": "2.0", "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
