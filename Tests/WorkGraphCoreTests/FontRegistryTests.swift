import CoreText
import XCTest
@testable import WorkGraphCore

final class FontRegistryTests: XCTestCase {
    /// 앱에 넣은 글꼴 폴더 (저장소 안 경로)
    private var brandFonts: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WorkGraphApp/Resources/Brand/Fonts", isDirectory: true)
    }

    func testBundledFontsRegisterUnderTheNamesTheViewsUse() {
        let names = Set(FontRegistry.register(directory: brandFonts))
        // BrandStyle 의 Brand.suit(…) 은 "SUIT-<굵기>", Brand.jost 는 "Jost-Book", Brand.jostLight 는 "Jost-Thin" 을 부른다
        XCTAssertEqual(names, ["SUIT-Regular", "SUIT-Medium", "SUIT-SemiBold", "SUIT-Bold", "Jost-Book", "Jost-Thin"])
        for name in names {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name, "\(name) 이 다른 글꼴로 대체됨")
        }
    }

    func testRegisteringTwiceStillReportsTheFonts() {
        _ = FontRegistry.register(directory: brandFonts)
        XCTAssertEqual(FontRegistry.register(directory: brandFonts).count, 6)
    }

    func testMissingFolderRegistersNothing() {
        XCTAssertEqual(FontRegistry.register(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")), [])
    }
}
