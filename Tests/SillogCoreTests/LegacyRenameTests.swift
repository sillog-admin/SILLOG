import XCTest
@testable import SillogCore

/// Data written under the old WorkGraph name must stay reachable after the rename.
final class LegacyRenameTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: base) }

    private func makeLegacy() throws -> URL {
        let legacy = base.appendingPathComponent("WorkGraph", isDirectory: true)
        try fm.createDirectory(at: legacy.appendingPathComponent("captures"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacy.appendingPathComponent("workgraph.sqlite"))
        try Data("wal".utf8).write(to: legacy.appendingPathComponent("workgraph.sqlite-wal"))
        try Data("jpg".utf8).write(to: legacy.appendingPathComponent("captures/a.jpg"))
        return legacy
    }

    func testMovesLegacyFolderRenamesDatabaseAndKeepsOldPathsWorking() throws {
        let legacy = try makeLegacy()
        let dir = SillogDatabase.migrateLegacyDirectory(in: base)

        XCTAssertEqual(dir.lastPathComponent, "Sillog")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sillog.sqlite"), encoding: .utf8), "db")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sillog.sqlite-wal"), encoding: .utf8), "wal")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("workgraph.sqlite").path))
        XCTAssertEqual(try legacy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("captures/a.jpg"), encoding: .utf8), "jpg", "absolute paths stored in the DB still resolve")
        XCTAssertEqual(SillogDatabase.migrateLegacyDirectory(in: base), dir, "second run is a no-op")
    }

    func testKeepsLegacyFolderWhileAnOldBuildHoldsItsLock() throws {
        let legacy = try makeLegacy()
        let running = InstanceLock(databasePath: legacy.appendingPathComponent("workgraph.sqlite").path)
        XCTAssertTrue(running.acquire())
        defer { running.release() }

        XCTAssertEqual(SillogDatabase.migrateLegacyDirectory(in: base), legacy)
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("Sillog").path))
    }

    func testLeavesBothAloneWhenTheNewFolderAlreadyExists() throws {
        let legacy = try makeLegacy()
        let current = base.appendingPathComponent("Sillog", isDirectory: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)

        XCTAssertEqual(SillogDatabase.migrateLegacyDirectory(in: base), current)
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("workgraph.sqlite").path))
    }

    func testDatabaseFileFallsBackToTheLegacyNameOnlyWhenAlone() throws {
        try Data().write(to: base.appendingPathComponent("workgraph.sqlite"))
        XCTAssertEqual(SillogDatabase.databaseFile(in: base).lastPathComponent, "workgraph.sqlite")
        try Data().write(to: base.appendingPathComponent("sillog.sqlite"))
        XCTAssertEqual(SillogDatabase.databaseFile(in: base).lastPathComponent, "sillog.sqlite")
    }

    func testEnvironmentPrefersNewNamesAndIgnoresEmptyValues() {
        XCTAssertEqual(SillogEnv.value("DB", in: ["SILLOG_DB": "/new", "WORKGRAPH_DB": "/old"]), "/new")
        XCTAssertEqual(SillogEnv.value("DB", in: ["SILLOG_DB": "", "WORKGRAPH_DB": "/old"]), "/old")
        XCTAssertNil(SillogEnv.value("DB", in: [:]))
    }
}
