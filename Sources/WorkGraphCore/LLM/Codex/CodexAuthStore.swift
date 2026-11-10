import Foundation

/// 앱 전용 토큰 저장소. Codex CLI(~/.codex/auth.json)나 gpt-proxy 와 파일을 공유하지 않는다.
/// refresh token 은 한 번 쓰면 새것으로 바뀌므로, 같은 토큰을 두 곳에서 들고 있으면
/// 나중에 쓰는 쪽이 "이미 사용된 토큰"을 보내 세션 전체가 무효가 된다. 그래서 앱은 자기 로그인을 따로 가진다.
public final class CodexAuthStore: @unchecked Sendable {
    public let fileURL: URL

    public init(fileURL: URL = CodexAuthStore.defaultURL()) { self.fileURL = fileURL }

    /// ~/Library/Application Support/WorkGraph/codex-auth.json (환경변수 WORKGRAPH_CODEX_AUTH 로 변경 가능)
    public static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["WORKGRAPH_CODEX_AUTH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return WGDatabase.defaultDirectory().appendingPathComponent("codex-auth.json")
    }

    public func load() -> CodexTokens? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CodexTokens.self, from: data)
    }

    /// 임시 파일에 쓰고 바꿔치기한다. 권한은 소유자만 읽고 쓰기(600).
    public func save(_ tokens: CodexTokens) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tokens)
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }

    /// 앱과 CLI 가 동시에 토큰을 갱신하지 않도록 프로세스 간 파일 잠금을 건다.
    public func withExclusiveLock<T>(_ body: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = fileURL.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return try await body() }        // 잠금 파일을 못 만들면 잠금 없이 진행
        defer { close(descriptor) }
        var waited = 0.0
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if waited >= 30 { break }                                   // 30초 넘게 막혀 있으면 그냥 진행
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }
}
