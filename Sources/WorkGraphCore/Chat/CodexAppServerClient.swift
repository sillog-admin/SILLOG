import AppKit
import Foundation

/// Codex가 검색·응답 루프를 실행하고, 앱의 자료·결과물 도구는 Sillog이 실행한다.
public struct CodexAppServerClient: Sendable {
    private let auth: any CodexCredentialProviding
    let model: String

    /// Args: auth는 앱이 관리하는 로그인, model은 채팅 설정에서 선택한 모델이다.
    /// Returns: Codex App Server 연결.
    /// Raises: 없음. CLI·인증 확인은 실행 시 수행한다.
    public init(auth: any CodexCredentialProviding, model: String) { self.auth = auth; self.model = model }

    /// Args: timeout은 연결 검사의 제한 시간(초)이다.
    /// Returns: 없음. 개인 자료 없이 실제 도구 호출과 최종 답변을 확인한다.
    /// Raises: 연결 실패, 도구 호출 누락, 시간 초과 또는 취소.
    public func checkConnection(timeout: TimeInterval = 45) async throws {
        let marker = UUID().uuidString
        let text = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await run(system: "Call connection_check, then reply with its returned text exactly.",
                              messages: [.init(role: "user", text: "Check the connection.")],
                              tools: [ChatTools.spec("connection_check", "Returns the connection test result.", [:])],
                              useWeb: false, execute: { _ in marker }, onEvent: { _ in })
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ChatToolError.unavailable("채팅 모델 연결 확인 시간이 초과되었습니다.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard text.contains(marker) else { throw ChatToolError.unavailable("Codex 도구 연결 확인에 실패했습니다.") }
    }

    /// Args: system·messages는 대화, tools·execute는 허용된 앱 도구, useWeb은 외부 검색 허용, onEvent는 화면 업데이트이다.
    /// Returns: Codex가 완료한 최종 답변.
    /// Raises: CLI 미설치, 인증·프로토콜·실행 오류, 취소.
    public func run(system: String, messages: [ChatModelMessage], tools: [ToolSpec], useWeb: Bool,
                    execute: @escaping @Sendable (ChatToolCall) async throws -> String,
                    onEvent: @escaping @Sendable (ChatRunEvent) async -> Void) async throws -> String {
        let connection = try CodexServerConnection()
        defer { connection.close() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try connection.start()
            try Task.checkCancellation()
            _ = try await connection.request("initialize", [
                "clientInfo": .object(["name": "sillog", "version": "1.0"]),
                "capabilities": .object(["experimentalApi": true]),
            ])
            try connection.send(["method": "initialized"])
            var credentials = try await auth.credentials()
            guard let accountID = credentials.accountId else { throw ChatToolError.unavailable("Codex 계정 정보가 없습니다. 설정에서 다시 로그인하세요.") }
            _ = try await connection.request("account/login/start", [
                "type": "chatgptAuthTokens", "accessToken": .string(credentials.accessToken), "chatgptAccountId": .string(accountID),
            ])
            let thread = try await connection.request("thread/start", [
                "model": .string(model), "cwd": .string(connection.directory.path), "ephemeral": true,
                "approvalPolicy": "never", "sandbox": "read-only", "environments": .array([]),
                "baseInstructions": .string(system + "\n코드·파일은 제공된 읽기 도구만 사용한다. 웹 출처는 답변에 Markdown 링크로 표시한다. 추가 정보가 필요하면 답변에서 사용자에게 질문한다."),
                "config": .object(["web_search": .string(useWeb ? "live" : "disabled")]),
                "dynamicTools": .array(tools.map { .object(["type": "function", "name": .string($0.name), "description": .string($0.description), "inputSchema": $0.parameters]) }),
            ])
            guard let threadID = thread["thread"]?.objectValue?["id"]?.stringValue else { throw ChatToolError.unavailable("Codex 대화를 시작하지 못했습니다.") }
            // 새 런타임에는 완료된 대화만 전달한다. 서버의 별도 대화 저장은 사용하지 않는다.
            let input = messages.map { "<message role=\"\($0.role)\">\n\($0.text)\n</message>" }.joined(separator: "\n")
            _ = try await connection.request("turn/start", [
                "threadId": .string(threadID), "input": .array([.object(["type": "text", "text": .string(input)])]),
                "effort": "medium", "approvalPolicy": "never",
                "environments": .array([]),
                "sandboxPolicy": .object(["type": "readOnly", "networkAccess": false]),
            ])
            var finalText = ""
            var toolCount = 0
            while let event = try await connection.next() {
                try Task.checkCancellation()
                let method = event["method"]?.stringValue ?? ""
                let params = event["params"]?.objectValue ?? [:]
                if let id = event["id"] {
                    switch method {
                    case "item/tool/call":
                        toolCount += 1
                        guard toolCount <= 32, let name = params["tool"]?.stringValue, tools.contains(where: { $0.name == name }) else {
                            throw ChatToolError.unavailable("Codex의 허용된 도구 실행 범위를 초과했습니다.")
                        }
                        let arguments = try JSONEncoder().encode(params["arguments"] ?? .object([:]))
                        let call = ChatToolCall(id: params["callId"]?.stringValue ?? UUID().uuidString, name: name, arguments: String(decoding: arguments, as: UTF8.self))
                        let output = try await execute(call)
                        try connection.send(["id": id, "result": .object(["success": true, "contentItems": .array([.object(["type": "inputText", "text": .string(output)])])])])
                    case "account/chatgptAuthTokens/refresh":
                        credentials = try await auth.refreshAfterRejection(of: credentials.accessToken)
                        try connection.send(["id": id, "result": .object(["accessToken": .string(credentials.accessToken), "chatgptAccountId": .string(credentials.accountId ?? accountID)])])
                    default:
                        // UI 밖의 권한 확대·명령 승인·사용자 입력 요청은 자동 승인하지 않는다.
                        try connection.send(["id": id, "error": .object(["code": -32601, "message": "Sillog does not permit this request. Ask the user in your reply."])])
                    }
                    continue
                }
                switch method {
                case "item/started":
                    let item = params["item"]?.objectValue ?? [:]
                    if item["type"]?.stringValue == "agentMessage" { await onEvent(.textReset) }
                    if item["type"]?.stringValue == "webSearch" { await onEvent(.step("웹 검색")) }
                case "item/agentMessage/delta":
                    await onEvent(.text(params["delta"]?.stringValue ?? ""))
                case "item/completed":
                    let item = params["item"]?.objectValue ?? [:]
                    if item["type"]?.stringValue == "agentMessage" { finalText = item["text"]?.stringValue ?? "" }
                case "turn/completed":
                    let turn = params["turn"]?.objectValue ?? [:]
                    guard turn["status"]?.stringValue == "completed" else {
                        throw ChatToolError.unavailable(turn["error"]?.objectValue?["message"]?.stringValue ?? "Codex 응답이 중단되었습니다.")
                    }
                    guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatToolError.unavailable("Codex가 최종 답변을 반환하지 않았습니다.") }
                    return finalText
                default: break
                }
            }
            try Task.checkCancellation()
            throw ChatToolError.unavailable("Codex 연결이 종료되었습니다. CLI 설치·네트워크 상태를 확인하세요.")
        } onCancel: { connection.close() }
    }
}

/// 채팅 실행과 모델 목록 조회에서 같은 Codex 실행기·버전을 사용한다.
enum CodexRuntime {
    static var paths: [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// Args: 없음.
    /// Returns: 앱 번들 또는 검색 경로에서 찾은 Codex 실행 파일.
    /// Raises: 실행 파일을 찾지 못하면 CLI 설치 안내 오류.
    static func executableURL() throws -> URL {
        let bundled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.appendingPathComponent("Contents/Resources/codex")
        let candidates = [bundled].compactMap { $0 } + paths.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ChatToolError.unavailable("Codex CLI가 필요합니다. Codex CLI를 설치한 뒤 앱을 다시 실행하세요.")
        }
        return executable
    }

    /// Args: 없음.
    /// Returns: 같은 실행 파일의 CLI 버전. 확인하지 못하면 nil.
    /// Raises: 없음. 버전 확인에는 별도의 임시 Codex 저장소를 사용한다.
    static func clientVersion() -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workgraph-codex-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process(), output = Pipe()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            process.executableURL = try executableURL()
            process.arguments = ["--version"]
            process.environment = ["PATH": paths.joined(separator: ":"), "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "CODEX_HOME": directory.path]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init)
        } catch { return nil }
    }
}

/// 한 작업에만 쓰는 stdio 연결. 사용자 Codex 설정·MCP·로그인 파일을 변경하거나 공유하지 않는다.
private final class CodexServerConnection: @unchecked Sendable {
    let directory: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    private var requestID = 0
    private var pending: [[String: JSONValue]] = []
    private let lock = NSLock()
    private var closed = false

    /// Args: 없음.
    /// Returns: 독립된 임시 작업 디렉터리와 JSONL 연결.
    /// Raises: CLI 미설치 또는 임시 디렉터리 생성 실패.
    init() throws {
        let paths = CodexRuntime.paths
        let executable = try CodexRuntime.executableURL()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workgraph-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        // 파일 조회는 앱의 범위 검사 도구를 이용한다. 셸·브라우저·플러그인 등 별도 실행 경로는 열지 않는다.
        for feature in ["shell_tool", "unified_exec", "code_mode", "apps", "plugins", "multi_agent", "browser_use", "computer_use", "view_image", "image_generation", "hooks", "memories", "shell_snapshot", "workspace_dependencies"] {
            process.arguments! += ["--disable", feature]
        }
        var childEnvironment = ["PATH": paths.joined(separator: ":"), "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        // 자식 프로세스의 전용 Codex 저장소이며 사용자의 실제 CODEX_HOME은 변경하지 않는다.
        childEnvironment["CODEX_HOME"] = directory.path
        process.environment = childEnvironment
        process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        process.terminationHandler = { [directory] _ in try? FileManager.default.removeItem(at: directory) }
    }

    /// Args: 없음.
    /// Returns: 없음. 취소와 시작이 겹치면 실행하지 않는다.
    /// Raises: 프로세스 실행 오류 또는 취소.
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        try process.run()
    }

    /// Args: 없음.
    /// Returns: 없음. 현재 작업의 서버를 중단하고 임시 자료를 정리한다.
    /// Raises: 없음.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        else { try? FileManager.default.removeItem(at: directory) }
    }

    /// Args: value는 요청·응답 JSON이다.
    /// Returns: 없음. 인증값을 로그나 파일에 쓰지 않고 파이프로 전달한다.
    /// Raises: JSON 인코딩·파이프 쓰기 오류.
    func send(_ value: [String: JSONValue]) throws {
        var data = try JSONEncoder().encode(JSONValue.object(value)); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Args: 없음.
    /// Returns: 서버의 다음 JSONL 메시지. EOF이면 nil.
    /// Raises: 파이프 읽기·JSON 디코딩 오류.
    func next() async throws -> [String: JSONValue]? {
        if !pending.isEmpty { return pending.removeFirst() }
        return try await readLine()
    }

    /// Args: 없음.
    /// Returns: 파이프의 다음 JSON 메시지.
    /// Raises: 읽기·디코딩 오류.
    private func readLine() async throws -> [String: JSONValue]? {
        guard let line = try await lines.next() else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue
    }

    /// Args: method·params는 초기화 단계의 순차 RPC 요청이다.
    /// Returns: 대응하는 서버 결과.
    /// Raises: 서버 오류·예상치 못한 연결 종료.
    func request(_ method: String, _ params: [String: JSONValue]) async throws -> [String: JSONValue] {
        requestID += 1
        let id = JSONValue.number(Double(requestID))
        try send(["id": id, "method": .string(method), "params": .object(params)])
        while let event = try await readLine() {
            if event["id"] == id, event["method"] == nil {
                if let error = event["error"]?.objectValue { throw ChatToolError.unavailable(error["message"]?.stringValue ?? "Codex 연결 오류") }
                return event["result"]?.objectValue ?? [:]
            }
            pending.append(event)
        }
        throw ChatToolError.unavailable("Codex 초기화 중 연결이 종료되었습니다. Codex CLI를 업데이트하세요.")
    }
}
