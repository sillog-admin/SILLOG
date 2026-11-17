import Foundation

/// Adds or removes SILLOG's MCP server in the config files of AI desktop apps.
public struct MCPRegistry: Sendable {
    /// Apps SILLOG can register itself in.
    public enum Client: String, CaseIterable, Sendable {
        case chatGPT, claude

        /// Claude rewrites its config from memory while it runs and drops an entry added meanwhile, so it must be closed first.
        public var closeFirstBundleID: String? { self == .claude ? "com.anthropic.claudefordesktop" : nil }
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    static let name = "sillog"
    let command: String
    let home: URL

    /// Args: command is the sillogctl path the apps will launch; home is the user's home folder.
    /// Returns: A registry that edits the config files under home.
    /// Raises: nothing.
    public init(command: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.command = command
        self.home = home
    }

    func configURL(_ client: Client) -> URL {
        switch client {
        case .chatGPT: home.appendingPathComponent(".codex/config.toml")
        case .claude: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        }
    }

    /// Returns: The JSON block other MCP apps accept, for the user to paste.
    public var snippet: String {
        Self.json(["mcpServers": [Self.name: ["command": command, "args": ["mcp"]]]])
    }

    /// Args: client is the app to check.
    /// Returns: Whether that app's config launches this SILLOG's sillogctl. An entry left by a moved app counts as not connected.
    /// Raises: nothing. An unreadable file counts as not connected.
    public func isConnected(_ client: Client) -> Bool {
        guard let text = try? String(contentsOf: configURL(client), encoding: .utf8) else { return false }
        return Self.registered(client, text) == command
    }

    /// Args: client is the app to register in.
    /// Raises: Failure when sillogctl is missing or the existing config can't be read, understood or written.
    public func connect(_ client: Client) throws {
        guard FileManager.default.isExecutableFile(atPath: command) else {
            throw Failure(errorDescription: tr("SILLOG 명령 도구를 찾지 못했어요. SILLOG을 다시 설치해 주세요."))
        }
        try edit(client) { text in
            switch client {
            case .chatGPT:
                let found = Self.scan(text)
                guard !found.conflict else {
                    throw Failure(errorDescription: tr("Codex 설정에 SILLOG 항목이 다른 형식으로 있어서 고치지 않았어요. ~/.codex/config.toml에서 직접 지워 주세요."))
                }
                var kept = found.kept.joined(separator: "\n")
                if !kept.isEmpty { kept += kept.hasSuffix("\n") ? "\n" : "\n\n" }
                let new = kept + "[mcp_servers.\(Self.name)]\ncommand = \(Self.tomlString(command))\nargs = [\"mcp\"]\n"
                // A line the scan misread could leave a second table, which Codex refuses to load.
                guard Self.scan(new).own.filter({ Self.tableHeader($0) != nil }).count == 1, Self.registered(client, new) == command else {
                    throw Failure(errorDescription: tr("Codex 설정에 SILLOG 항목이 다른 형식으로 있어서 고치지 않았어요. ~/.codex/config.toml에서 직접 지워 주세요."))
                }
                return new
            case .claude:
                var root = try Self.claudeRoot(text)
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers[Self.name] = ["command": command, "args": ["mcp"]]
                root["mcpServers"] = servers
                return Self.json(root)
            }
        }
    }

    /// Args: client is the app to remove SILLOG from.
    /// Raises: Failure when the existing config can't be read or written.
    public func disconnect(_ client: Client) throws {
        try edit(client) { text in
            guard Self.registered(client, text) != nil else { return text }
            switch client {
            case .chatGPT:
                return Self.scan(text).kept.joined(separator: "\n")
            case .claude:
                var root = try Self.claudeRoot(text)
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers[Self.name] = nil
                root["mcpServers"] = servers
                return Self.json(root)
            }
        }
    }

    /// Args: client picks the config file; change maps its old text to the new text.
    /// Raises: Failure when the file can't be read or written, and whatever change throws. Nothing is written when the text is unchanged.
    private func edit(_ client: Client, _ change: (String) throws -> String) throws {
        // Dotfile managers link these files; writing through the link keeps it.
        let url = configURL(client).resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let old = exists ? try? String(contentsOf: url, encoding: .utf8) : "" else {
            throw Failure(errorDescription: tr("\(url.path) 파일을 읽지 못했어요."))
        }
        let new = try change(old)
        guard new != old else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // These files can hold tokens, so the rewrite and the backup keep the original's permissions.
            let mode = exists ? try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] : nil
            let backup = url.appendingPathExtension("sillog-backup")
            // The user's other settings live in this file too; keep the last copy in case an edit goes wrong.
            if exists { try old.write(to: backup, atomically: true, encoding: .utf8) }
            try new.write(to: url, atomically: true, encoding: .utf8)
            if let mode {
                for file in [url, backup] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
            }
        } catch {
            throw Failure(errorDescription: tr("\(url.path) 파일을 고치지 못했어요. (\(error.localizedDescription))"))
        }
    }

    /// Returns: The command SILLOG's entry launches, "" for an entry without one, nil when there is no entry.
    static func registered(_ client: Client, _ text: String) -> String? {
        switch client {
        case .chatGPT:
            let own = scan(text).own
            guard !own.isEmpty else { return nil }
            let pairs = own.map { $0.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) } }
            guard let value = pairs.first(where: { $0.count == 2 && $0[0] == "command" })?[1] else { return "" }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        case .claude:
            guard let entry = (object(text)?["mcpServers"] as? [String: Any])?[name] else { return nil }
            return (entry as? [String: Any])?["command"] as? String ?? ""
        }
    }

    /// The Codex config split into SILLOG's tables and everything else.
    struct CodexScan {
        var kept: [Substring] = []
        var own: [Substring] = []
        /// mcp_servers.sillog is also defined some other way, so adding the table would make the file invalid.
        var conflict = false
    }

    /// Walks the TOML line by line, skipping multi-line strings, and sorts lines into SILLOG's tables and the rest.
    static func scan(_ text: String) -> CodexScan {
        var result = CodexScan(), table = "", openString: String?
        // Blank lines inside SILLOG's table wait to see whether a user comment follows; afterComment means one did.
        var blanks: [Substring] = [], afterComment = false
        // Only LF and CRLF end a TOML line; U+2028 and the like are legal inside strings and comments.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let header = openString == nil ? tableHeader(line) : nil
            if let header { result.own += blanks; blanks = []; afterComment = false; table = header }
            let code = line.trimmingCharacters(in: .whitespaces)
            if !isOwn(table) {
                if openString == nil, header == nil {
                    let key = line.filter { !"\" \t'".contains($0) }
                    if table.isEmpty, key.hasPrefix("mcp_servers=") || key.hasPrefix("mcp_servers.\(name)=") || key.hasPrefix("mcp_servers.\(name).") { result.conflict = true }
                    if table == "mcp_servers", key.hasPrefix("\(name)=") || key.hasPrefix("\(name).") { result.conflict = true }
                }
                result.kept.append(line)
            } else if openString != nil || header != nil {
                result.own.append(line)
            } else if code.isEmpty {
                if afterComment { result.kept.append(line) } else { blanks.append(line) }
            } else if code.hasPrefix("#") {
                // SILLOG's table sits at the end, so comments below it are the user's notes for what comes next.
                result.kept += blanks + [line]; blanks = []; afterComment = true
            } else {
                result.own += blanks + [line]; blanks = []; afterComment = false
            }
            openString = openStringAfter(line, from: openString)
        }
        result.own += blanks
        return result
    }

    /// Returns: The multi-line string delimiter still open after this line, given the one open before it. Quotes in comments and one-line strings don't count.
    static func openStringAfter(_ line: Substring, from open: String?) -> String? {
        var open = open, quote: Character?, i = line.startIndex
        func skip(_ n: Int) { i = line.index(i, offsetBy: n, limitedBy: line.endIndex) ?? line.endIndex }
        while i < line.endIndex {
            let rest = line[i...], c = line[i]
            if let mark = open {
                if rest.hasPrefix(mark) { open = nil; skip(3); continue }
                if mark == "\"\"\"", c == "\\" { skip(2); continue }
            } else if let q = quote {
                if q == "\"", c == "\\" { skip(2); continue }
                if c == q { quote = nil }
            } else if rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") {
                open = String(rest.prefix(3)); skip(3); continue
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                break
            }
            skip(1)
        }
        return open
    }

    static func isOwn(_ header: String) -> Bool {
        header == "mcp_servers.\(name)" || header.hasPrefix("mcp_servers.\(name).")
    }

    /// Returns: The name of a `[table]` or `[[array]]` header without quotes and spaces, nil for any other line.
    static func tableHeader(_ line: Substring) -> String? {
        var code = "", quote: Character?, comma = false
        for c in line.drop(while: \.isWhitespace) {
            if let open = quote { if c == open { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "#" { break }
            else if c == "," { comma = true }
            code.append(c)
        }
        code = code.trimmingCharacters(in: .whitespaces)
        // An element of a multi-line array also starts with "[", but holds commas between its values.
        guard code.hasPrefix("["), code.hasSuffix("]"), !comma else { return nil }
        return code.filter { !"[]\"' ".contains($0) }
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// Returns: The config's top-level object, empty for a blank file.
    /// Raises: Failure when the text isn't a JSON object, so a file Claude can't read either is never overwritten.
    static func claudeRoot(_ text: String) throws -> [String: Any] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let root = object(text) else {
            throw Failure(errorDescription: tr("Claude 설정 파일이 올바른 JSON이 아니라서 고치지 않았어요."))
        }
        return root
    }

    static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
