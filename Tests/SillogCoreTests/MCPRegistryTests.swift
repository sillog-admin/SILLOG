import XCTest
@testable import SillogCore

final class MCPRegistryTests: XCTestCase {
    private var home: URL!
    private var registry: MCPRegistry!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let tool = home.appendingPathComponent("sillogctl")
        FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        registry = MCPRegistry(command: tool.path, home: home)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func write(_ text: String, _ client: MCPRegistry.Client) throws {
        let url = registry.configURL(client)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ client: MCPRegistry.Client) throws -> String { try String(contentsOf: registry.configURL(client), encoding: .utf8) }

    func testCodexConfigKeepsOtherSettingsAndHoldsOneSillogTable() throws {
        let original = """
        model = "gpt-6"

        [mcp_servers.other]
        command = "other"
        args = [
        "a",
        ]

        [projects."/Users/me/app"]
        trust_level = "trusted"

        """
        try write(original, .chatGPT)
        XCTAssertFalse(registry.isConnected(.chatGPT))

        try registry.connect(.chatGPT)
        try registry.connect(.chatGPT)
        let connected = try read(.chatGPT)
        XCTAssertTrue(registry.isConnected(.chatGPT))
        XCTAssertEqual(connected.components(separatedBy: "[mcp_servers.SILLOG]").count, 2)
        XCTAssertTrue(connected.hasPrefix(original))
        XCTAssertTrue(connected.contains("command = \"\(registry.command)\"\nargs = [\"mcp\"]"))

        // Codex may write its own tables after ours.
        try write(connected + "\n[mcp_servers.SILLOG.env]\nA = \"1\"\n\n[projects.\"/Users/me/next\"]\ntrust_level = \"trusted\"\n", .chatGPT)
        try registry.disconnect(.chatGPT)
        XCTAssertEqual(try read(.chatGPT), original + "\n[projects.\"/Users/me/next\"]\ntrust_level = \"trusted\"\n")
        XCTAssertFalse(registry.isConnected(.chatGPT))
    }

    func testCodexConfigEdgeCasesKeepTheUsersTables() throws {
        let line = "command = \"\(registry.command)\"\nargs = [\"mcp\"]"
        // CRLF file that already has the table: found, and replaced rather than added twice.
        try write("model = \"o3\"\r\n\r\n[mcp_servers.SILLOG]\r\ncommand = \"/old\"\r\n", .chatGPT)
        XCTAssertFalse(registry.isConnected(.chatGPT), "an entry for another path is stale")
        try registry.connect(.chatGPT)
        XCTAssertEqual(try read(.chatGPT), "model = \"o3\"\n\n[mcp_servers.SILLOG]\n\(line)\n")

        // Indented headers, a comment holding "]", and a multi-line string that mentions the table.
        let others = "  [profiles.work]  # see [docs] for options\n  model = \"o3\"\n[tui] # a [b] c\nx = \"\"\"\n[mcp_servers.SILLOG]\n\"\"\"\n"
        try write(try read(.chatGPT) + others, .chatGPT)
        XCTAssertTrue(registry.isConnected(.chatGPT))
        try registry.disconnect(.chatGPT)
        XCTAssertEqual(try read(.chatGPT), "model = \"o3\"\n\n" + others)
        XCTAssertFalse(registry.isConnected(.chatGPT))
    }

    func testTripleQuotesOutsideStringsAndCommentsBelowOurTableAreHandled() throws {
        let line = "command = \"\(registry.command)\"\nargs = [\"mcp\"]"
        // Triple quotes in a comment and inside one-line strings open no multi-line string.
        let top = "# wrap long prompts in \"\"\"\nx = '\"\"\"'\ny = \"a'''b\"\nz = \"one\u{2028}[two]\"\n\n"
        try write(top + "[mcp_servers.SILLOG]\ncommand = \"/old\"\n", .chatGPT)
        try registry.connect(.chatGPT)
        XCTAssertEqual(try read(.chatGPT), top + "[mcp_servers.SILLOG]\n\(line)\n")

        let notes = "\n# [mcp_servers.old]\n# command = \"x\"\n\n[tui]\nx = 1\n"
        try write(try read(.chatGPT) + notes, .chatGPT)
        try registry.disconnect(.chatGPT)
        XCTAssertEqual(try read(.chatGPT), top + notes)
    }

    func testCodexConfigWithAnotherFormOfTheEntryIsLeftAlone() throws {
        for text in ["[mcp_servers]\nSILLOG = { command = \"x\" }\n", "mcp_servers.SILLOG.command = \"x\"\n", "mcp_servers = { a = { command = \"x\" } }\n"] {
            try write(text, .chatGPT)
            XCTAssertThrowsError(try registry.connect(.chatGPT), text)
            XCTAssertEqual(try read(.chatGPT), text)
        }
    }

    func testEditsKeepPermissionsAndSymlinks() throws {
        let target = home.appendingPathComponent("dotfiles/config.toml")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"o3\"\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = registry.configURL(.chatGPT)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try registry.connect(.chatGPT)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("[mcp_servers.SILLOG]"))
        for file in [target, target.appendingPathExtension("sillog-backup")] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600, file.path)
        }
    }

    func testCodexConfigIsCreatedWhenMissing() throws {
        try registry.connect(.chatGPT)
        XCTAssertEqual(try read(.chatGPT), "[mcp_servers.SILLOG]\ncommand = \"\(registry.command)\"\nargs = [\"mcp\"]\n")
    }

    func testClaudeGetsAnExtensionWithTheSILLOGNameAndLogo() throws {
        let icon = Data([0x89, 0x50, 0x4E, 0x47])
        let file = try XCTUnwrap(try MCPRegistry(command: registry.command, home: home, icon: icon).connect(.claude))
        XCTAssertEqual(file.pathExtension, "mcpb")
        let out = home.appendingPathComponent("unpacked")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", file.path, out.path]
        try unzip.run()
        unzip.waitUntilExit()
        let manifest = try XCTUnwrap(MCPRegistry.object(try String(contentsOf: out.appendingPathComponent("manifest.json"), encoding: .utf8)))
        XCTAssertEqual(manifest["display_name"] as? String, "SILLOG")
        XCTAssertEqual(manifest["icon"] as? String, "icon.png")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("icon.png")), icon)
        let config = (manifest["server"] as? [String: Any])?["mcp_config"] as? [String: Any]
        XCTAssertEqual(config?["command"] as? String, registry.command)
        XCTAssertEqual(config?["args"] as? [String], ["mcp"])

        // Claude unpacks it into a folder it names itself.
        XCTAssertFalse(registry.isConnected(.claude))
        let installed = registry.configURL(.claude).appendingPathComponent("local.mcpb.sillog.sillog")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: out, to: installed)
        XCTAssertTrue(registry.isConnected(.claude))
        XCTAssertThrowsError(try registry.disconnect(.claude))
    }

    func testMissingToolIsReported() {
        let missing = MCPRegistry(command: home.appendingPathComponent("none").path, home: home)
        XCTAssertThrowsError(try missing.connect(.chatGPT))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.configURL(.chatGPT).path))
    }

    func testSnippetNamesTheTool() throws {
        let servers = MCPRegistry.object(registry.snippet)?["mcpServers"] as? [String: Any]
        XCTAssertEqual((servers?["SILLOG"] as? [String: Any])?["args"] as? [String], ["mcp"])
    }
}
