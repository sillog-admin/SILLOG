import Foundation

/// Adds or removes SILLOG's MCP server in the config files of AI desktop apps.
public struct MCPRegistry: Sendable {
    /// Apps SILLOG can register itself in.
    public enum Client: String, CaseIterable, Sendable {
        case chatGPT, claude
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    // ChatGPT shows this key as the server name and ignores serverInfo.
    static let name = "SILLOG"
    let command: String
    let home: URL
    let icon: Data

    /// Args: command is the sillogctl path the apps will launch; home is the user's home folder; icon is the PNG Claude shows for the extension.
    /// Returns: A registry that edits the config files under home.
    /// Raises: nothing.
    public init(command: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, icon: Data = Data()) {
        self.command = command
        self.home = home
        self.icon = icon
    }

    func configURL(_ client: Client) -> URL {
        switch client {
        case .chatGPT: home.appendingPathComponent(".codex/config.toml")
        case .claude: home.appendingPathComponent("Library/Application Support/Claude/Claude Extensions")
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
        switch client {
        case .chatGPT:
            guard let text = try? String(contentsOf: configURL(client), encoding: .utf8) else { return false }
            return Self.registered(text) == command
        case .claude:
            // Claude names the extension folder itself, so look for our manifest in any of them.
            let folders = (try? FileManager.default.contentsOfDirectory(at: configURL(client), includingPropertiesForKeys: nil)) ?? []
            return folders.contains { folder in
                let manifest = Self.object((try? String(contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8)) ?? "")
                let config = (manifest?["server"] as? [String: Any])?["mcp_config"] as? [String: Any]
                return manifest?["name"] as? String == Self.extensionName && config?["command"] as? String == command
            }
        }
    }

    /// Args: client is the app to register in.
    /// Returns: For Claude, the .mcpb file to open in Claude, which asks the user to install it. Nil for ChatGPT.
    /// Raises: Failure when sillogctl is missing, the existing config can't be read, understood or written, or the extension can't be packed.
    @discardableResult
    public func connect(_ client: Client) throws -> URL? {
        guard FileManager.default.isExecutableFile(atPath: command) else {
            throw Failure(errorDescription: tr("SILLOG 명령 도구를 찾지 못했어요. SILLOG을 다시 설치해 주세요."))
        }
        guard client == .chatGPT else { return try claudeExtension() }
        try edit(client) { text in
            let found = Self.scan(text)
            guard !found.conflict else {
                throw Failure(errorDescription: tr("Codex 설정에 SILLOG 항목이 다른 형식으로 있어서 고치지 않았어요. ~/.codex/config.toml에서 직접 지워 주세요."))
            }
            var kept = found.kept.joined(separator: "\n")
            if !kept.isEmpty { kept += kept.hasSuffix("\n") ? "\n" : "\n\n" }
            let new = kept + "[mcp_servers.\(Self.name)]\ncommand = \(Self.tomlString(command))\nargs = [\"mcp\"]\n"
            // A line the scan misread could leave a second table, which Codex refuses to load.
            guard Self.scan(new).own.filter({ Self.tableHeader($0) != nil }).count == 1, Self.registered(new) == command else {
                throw Failure(errorDescription: tr("Codex 설정에 SILLOG 항목이 다른 형식으로 있어서 고치지 않았어요. ~/.codex/config.toml에서 직접 지워 주세요."))
            }
            return new
        }
        return nil
    }

    /// Args: client is the app to remove SILLOG from.
    /// Raises: Failure when the existing config can't be read or written, and always for Claude, whose extensions only Claude can remove.
    public func disconnect(_ client: Client) throws {
        guard client == .chatGPT else {
            throw Failure(errorDescription: tr("Claude 설정에서 SILLOG 확장 프로그램을 제거해 주세요."))
        }
        try edit(client) { text in
            Self.registered(text) == nil ? text : Self.scan(text).kept.joined(separator: "\n")
        }
    }

    static let extensionName = "sillog"

    /// Claude shows a custom name and logo only for extensions, not for servers in claude_desktop_config.json.
    /// Returns: A .mcpb file in the temporary folder that launches sillogctl.
    /// Raises: Failure when the file can't be written or packed.
    func claudeExtension() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SILLOG-mcpb-\(UUID().uuidString)")
        let file = folder.appendingPathExtension("mcpb")
        let manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": Self.extensionName,
            "display_name": "SILLOG",
            "version": "1.0.0",
            "description": tr("SILLOG에 남은 업무, 화면, 녹음, 대화 기록을 찾아 읽어요."),
            "author": ["name": "SILLOG", "url": "https://sillog.app"],
            "homepage": "https://sillog.app",
            "icon": "icon.png",
            // sillogctl lives in SILLOG.app, so the extension only points at it instead of carrying a copy.
            "server": ["type": "binary", "entry_point": command, "mcp_config": ["command": command, "args": ["mcp"]]],
            "compatibility": ["platforms": ["darwin"]],
        ]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.json(manifest).write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try icon.write(to: folder.appendingPathComponent("icon.png"))
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", folder.path, file.path]
            try zip.run()
            zip.waitUntilExit()
            try? FileManager.default.removeItem(at: folder)
            guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            throw Failure(errorDescription: tr("Claude 확장 파일을 만들지 못했어요. (\(error.localizedDescription))"))
        }
        return file
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

    /// Returns: The command SILLOG's Codex entry launches, "" for an entry without one, nil when there is no entry.
    static func registered(_ text: String) -> String? {
        let own = scan(text).own
        guard !own.isEmpty else { return nil }
        let pairs = own.map { $0.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) } }
        guard let value = pairs.first(where: { $0.count == 2 && $0[0] == "command" })?[1] else { return "" }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// The Codex config split into SILLOG's tables and everything else.
    struct CodexScan {
        var kept: [Substring] = []
        var own: [Substring] = []
        /// mcp_servers.SILLOG is also defined some other way, so adding the table would make the file invalid.
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

    static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
