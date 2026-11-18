import XCTest
@testable import SillogCore

final class UpdateCheckTests: XCTestCase {
    func testNewerBuildOnlyWithDmgLink() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let release = #"{"tag_name":"v0.1.0-build.77","html_url":"https://github.com/sillog-admin/SILLOG/releases/tag/v0.1.0-build.77","assets":[{"name":"SILLOG.dmg","browser_download_url":"https://github.com/sillog-admin/SILLOG/releases/download/v0.1.0-build.77/SILLOG.dmg"}]}"#
        StubURLProtocol.reset([.init(status: 200, body: release), .init(status: 200, body: release), .init(status: 200, body: release),
                               .init(status: 200, body: #"{"tag_name":"v0.1.0","html_url":"https://example.com"}"#), .init(status: 403, body: "{}")])

        let update = await UpdateCheck.latest(currentBuild: 76, session: session)
        XCTAssertEqual(update, .init(build: 77, url: URL(string: "https://github.com/sillog-admin/SILLOG/releases/download/v0.1.0-build.77/SILLOG.dmg")!))
        let latest = await UpdateCheck.latest(currentBuild: 77, session: session)
        XCTAssertNil(latest)
        let older = await UpdateCheck.latest(currentBuild: 80, session: session)
        XCTAssertNil(older)
        let malformed = await UpdateCheck.latest(currentBuild: 1, session: session)
        XCTAssertNil(malformed)
        let failed = await UpdateCheck.latest(currentBuild: 1, session: session)
        XCTAssertNil(failed)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url, UpdateCheck.latestURL)
        XCTAssertEqual(request.headers["User-Agent"], "SILLOG")
        let noDmg = UpdateCheck.parse(Data(#"{"tag_name":"v0.1.0-build.9","html_url":"https://github.com/r","assets":[]}"#.utf8), currentBuild: 8)
        XCTAssertEqual(noDmg?.url.absoluteString, "https://github.com/r")
    }

    func testTheInstallerRejectsAnAppSignedByAnotherIdentity() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"))
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("SILLOG.app"), macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("SILLOG").path)
        let info: [String: Any] = ["CFBundleIdentifier": Bundle.main.bundleIdentifier ?? "com.sillog.app", "CFBundleExecutable": "SILLOG"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-s", "-", "--force", app.path])
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)

        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(app as CFURL, [], &code), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), [], nil), errSecSuccess, "validly signed, just not by us")
        XCTAssertThrowsError(try UpdateInstaller.verify(app)) { XCTAssertTrue("\($0)".hasPrefix("signature check"), "\($0)") }
    }
}
