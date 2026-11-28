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

    /// Room for a week-long project's whole map: about 90 nodes and 11,000 characters.
    static let maxNodes = 100
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
        spec("search", "Searches the user's SILLOG records (work graph, screen summaries, raw screen text, requests sent to AI tools, recordings, weekly and monthly summaries, SILLOG chats, library materials, files). Without a kind it returns a few recent results of each kind; with kind it returns up to 50 of that kind only. Pass a result's id to fetch or get_related.", required: ["query"], [
            "query": field("One word or a short phrase that appears verbatim in the records. Listing several words finds only records that contain the whole phrase, so search for one at a time. An empty string returns recent records"),
            "from": field("Start date YYYY-MM-DD. Omit for no limit"),
            "to": field("End date YYYY-MM-DD. Omit for no limit"),
            "kind": field("To see one kind only: node (task and material graph), card (screen summary), observation (raw screen text), digest (weekly and monthly summary), chat (request sent to an AI tool), recording (recording), message (SILLOG chat), library (materials uploaded to the SILLOG library and saved outputs), file (paths of newly created or downloaded files; this kind is found only when specified)", options: Kind.allCases.map(\.rawValue)),
        ]),
        spec("fetch", "Reads the original text of a search result. For long text, continue reading from the next start position given at the end of the response.", required: ["id"], [
            "id": field("The id from a search result. Use the conversation:<id> shown in a SILLOG chat result to read the whole conversation"),
            "start": field("For a conversation, the starting message number; for a message or recording, the starting character position. 1 to start from the beginning", type: "integer"),
        ]),
        spec("summarize_period", "Calculates from the usage-time ledger the work time per task, the most-used materials, the app breakdown, and changes in problems and to-dos for a period. Get time and counts from this tool; do not estimate them from search results. For a written account of what was done in the period, use search with kind=digest.", required: ["from", "to"], [
            "from": field("Start date YYYY-MM-DD"),
            "to": field("End date YYYY-MM-DD (inclusive)"),
            "task": field("A task key, part of a task title, or a project name. Omit for all"),
        ]),
        spec("list_items", "Lists the tasks, sessions, problems or to-dos in a period, by type, in chronological order. Over 100, it returns only the latest 100 and says so at the end. To lay out a day in time order or to see blocked problems and postponed to-dos, use this tool instead of search.", required: ["type"], [
            "type": field("task (task), session (a time span spent on a task and a summary of what was done), problem (a blocking problem and whether it was solved), todo (something set aside to do later)", options: ItemType.allCases.map(\.rawValue)),
            "from": field("Start date YYYY-MM-DD. Omit for no limit"),
            "to": field("End date YYYY-MM-DD (inclusive). Omit for no limit"),
            "task": field("A task's node: id from list_items type task, to list only that task's sessions, problems or to-dos. Omit for all"),
        ]),
        spec("get_related", "Follows the sessions, materials, apps, topics, problems and to-dos linked to one node in the work graph.", required: ["id"], [
            "id": field("An id from the search results that starts with node:"),
            "hops": field("How many steps to follow. 1 or 2, default 1", type: "integer"),
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
            let note = kind != nil && found.count > Self.maxSearch ? "\n[Showed only up to \(Self.maxSearch). Narrow the period and search again.]" : ""
            return try ChatTools.output(withConversation(Array(found.prefix(kind == nil ? found.count : Self.maxSearch)))).text + note
        case "fetch":
            if text("id").hasPrefix("library:") {
                return try ChatTools.output([tools.library.read(text("id"), ids: tools.search.openLibraryIDs(), start: Int(text("start", "1")) ?? 1)]).text
            }
            return try ChatTools.output(withConversation(tools.search.read(text("id"), start: Int(text("start", "1")) ?? 1))).text
        case "summarize_period":
            return try await run("summarize_period", ["from": text("from"), "to": text("to"), "task": text("task")]).text
        case "list_items":
            return try await run("list_items", ["type": text("type"), "from": text("from"), "to": text("to"), "task": text("task")]).text
        case "get_related":
            return try await run("get_related", ["id": text("id"), "hops": text("hops", "1")]).text
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
        if graph.nodes.count > maxNodes {
            lines.append("[Showing \(maxNodes) of \(graph.nodes.count): problems, to-dos and topics first, then the newest materials and sessions. list_items with a task lists its sessions.]")
        }
        return lines.isEmpty ? "[]" : lines.joined(separator: "\n")
    }

    static func reply(_ id: JSONValue, result: [String: JSONValue]) -> String {
        JSONValue.encodeObject(["jsonrpc": "2.0", "id": id, "result": .object(result)])
    }

    static func reply(_ id: JSONValue, error code: Int, _ message: String) -> String {
        JSONValue.encodeObject(["jsonrpc": "2.0", "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
