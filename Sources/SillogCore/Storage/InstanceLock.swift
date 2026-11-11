import Foundation

/// 같은 DB 로 두 인스턴스가 동시에 수집하면 행이 중복된다 (예: .app 과 `swift run` 을 같이 띄운 경우).
/// DB 옆에 잠금 파일을 두고, 먼저 뜬 쪽만 수집한다. 프로세스가 끝나면 잠금은 자동으로 풀린다.
public final class InstanceLock: @unchecked Sendable {
    private let path: String
    private var descriptor: Int32 = -1

    public init(path: String) { self.path = path }

    public convenience init(databasePath: String) { self.init(path: databasePath + ".instance.lock") }

    public func acquire() -> Bool {
        if descriptor >= 0 { return true }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }                 // 잠금 파일을 못 만드는 환경이면 막지 않는다
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
