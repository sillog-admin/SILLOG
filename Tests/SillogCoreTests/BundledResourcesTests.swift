import XCTest
@testable import SillogCore

final class BundledResourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wg-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fake .app shaped like make-app.sh's, with Brand/Fonts and Core's bundle in Contents/Resources when asked.
    private func fakeApp(withFonts: Bool, withCore: Bool = false) throws -> Bundle {
        let app = root.appendingPathComponent("Fake.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.fake</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>"#
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        if withFonts { try FileManager.default.createDirectory(at: resources.appendingPathComponent("Brand/Fonts"), withIntermediateDirectories: true) }
        if withCore {
            let core = resources.appendingPathComponent("Sillog_SillogCore.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
            try #"{"오늘": "Today"}"#.write(to: core.appendingPathComponent("en.json"), atomically: true, encoding: .utf8)
        }
        return try XCTUnwrap(Bundle(url: app))
    }

    /// The released app crashed on launch: Bundle.module looks only at the app root and the CI build folder.
    func testAppFindsCoreResourcesInContentsResources() throws {
        let app = try fakeApp(withFonts: false, withCore: true)
        let core = BundledResources.coreBundle(main: app) {
            XCTFail("Bundle.module ends an .app that runs away from the build machine")
            return Bundle.main
        }
        XCTAssertNotNil(core?.url(forResource: "en", withExtension: "json"))
    }

    func testAppWithoutCoreBundleGetsNilInsteadOfACrash() throws {
        let app = try fakeApp(withFonts: false)
        XCTAssertNil(BundledResources.coreBundle(main: app) {
            XCTFail("Bundle.module ends an .app that runs away from the build machine")
            return Bundle.main
        })
    }

    func testSwiftRunAndTestsStillLoadTheEnglishTable() {
        XCTAssertNotNil(BundledResources.core?.url(forResource: "en", withExtension: "json"))
        XCTAssertFalse(L10n.english.isEmpty)
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
        let module = root.appendingPathComponent("Sillog_SillogApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: module.appendingPathComponent("Brand/Fonts"), withIntermediateDirectories: true)
        let plain = root.appendingPathComponent("debug", isDirectory: true)                // swift run 의 실행 파일 폴더
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let url = BundledResources.url(forResource: "Fonts", withExtension: nil, subdirectory: "Brand",
                                       main: try XCTUnwrap(Bundle(url: plain))) { Bundle(url: module)! }
        XCTAssertEqual(url?.standardizedFileURL.path.hasSuffix("Sillog_SillogApp.bundle/Brand/Fonts"), true)
    }
}
