import XCTest
@testable import WorkGraphCore

final class InstanceLockTests: XCTestCase {
    func testSecondInstanceCannotTakeTheSameLock() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wg-lock-\(UUID().uuidString).lock").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = InstanceLock(path: path), second = InstanceLock(path: path)
        XCTAssertTrue(first.acquire())
        XCTAssertTrue(first.acquire(), "이미 잡은 쪽이 다시 불러도 그대로 성공")
        XCTAssertFalse(second.acquire(), "같은 데이터로 두 번째 인스턴스는 잠금을 못 잡는다")
        first.release()
        XCTAssertTrue(second.acquire(), "먼저 뜬 쪽이 끝나면 잡을 수 있다")
    }

    func testDifferentDataFoldersDoNotBlockEachOther() {
        let a = InstanceLock(path: FileManager.default.temporaryDirectory.appendingPathComponent("wg-a-\(UUID().uuidString).lock").path)
        let b = InstanceLock(path: FileManager.default.temporaryDirectory.appendingPathComponent("wg-b-\(UUID().uuidString).lock").path)
        XCTAssertTrue(a.acquire())
        XCTAssertTrue(b.acquire())
    }
}
