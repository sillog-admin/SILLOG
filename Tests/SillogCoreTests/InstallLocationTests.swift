import XCTest
@testable import SillogCore

final class InstallLocationTests: XCTestCase {
    func testAppOnAWritableVolumeStarts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("SILLOG.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertFalse(InstallLocation.needsMove(app))
    }

    /// Opened in place from a quarantined dmg, macOS runs the app from a random read-only copy that a restart removes.
    func testTranslocatedCopyAsksToBeMoved() {
        let app = URL(fileURLWithPath: "/private/var/folders/x1/abc/T/AppTranslocation/6A1E2F3B-0000-4000-8000-000000000000/d/SILLOG.app")
        XCTAssertTrue(InstallLocation.needsMove(app))
    }

    func testSwiftRunIsNeverAsked() {
        XCTAssertFalse(InstallLocation.needsMove(URL(fileURLWithPath: "/private/var/folders/x1/abc/T/AppTranslocation/x/d")), "only an .app is moved")
    }
}
