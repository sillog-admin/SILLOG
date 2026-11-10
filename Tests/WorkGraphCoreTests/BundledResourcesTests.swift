import XCTest
@testable import WorkGraphCore

final class BundledResourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wg-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// make-app.sh 가 만드는 모양의 가짜 .app. withFonts 면 Contents/Resources/Brand/Fonts 를 둔다
    private func fakeApp(withFonts: Bool) throws -> Bundle {
        let app = root.appendingPathComponent("Fake.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.fake</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>"#
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        if withFonts { try FileManager.default.createDirectory(at: resources.appendingPathComponent("Brand/Fonts"), withIntermediateDirectories: true) }
        return try XCTUnwrap(Bundle(url: app))
    }

    func testAppWithoutTheFolderNeverTouchesTheSwiftPMBundle() throws {
        let app = try fakeApp(withFonts: false)
        let url = BundledResources.url(forResource: "Fonts", withExtension: nil, subdirectory: "Brand", main: app) {
            XCTFail(".app 에서 Bundle.module 을 부르면 리소스 번들이 없어 앱이 끝난다")
            return Bundle.main
        }
        XCTAssertNil(url, "없으면 nil 이고, 앱은 시스템 글꼴로 뜬다")
    }

    func testAppFindsItsOwnResources() throws {
        let app = try fakeApp(withFonts: true)
        let url = BundledResources.url(forResource: "Fonts", withExtension: nil, subdirectory: "Brand", main: app) { Bundle.main }
        XCTAssertEqual(url?.standardizedFileURL.path.hasSuffix("Contents/Resources/Brand/Fonts"), true)
    }

    func testCommandLineRunUsesTheSwiftPMBundle() throws {
        let module = root.appendingPathComponent("WorkGraph_WorkGraphApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: module.appendingPathComponent("Brand/Fonts"), withIntermediateDirectories: true)
        let plain = root.appendingPathComponent("debug", isDirectory: true)                // swift run 의 실행 파일 폴더
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let url = BundledResources.url(forResource: "Fonts", withExtension: nil, subdirectory: "Brand",
                                       main: try XCTUnwrap(Bundle(url: plain))) { Bundle(url: module)! }
        XCTAssertEqual(url?.standardizedFileURL.path.hasSuffix("WorkGraph_WorkGraphApp.bundle/Brand/Fonts"), true)
    }
}
