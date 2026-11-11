import XCTest
@testable import SillogCore

final class L10nTests: XCTestCase {
    override func tearDown() { L10n.current = .ko }

    func testInterpolationBecomesPlaceholdersAndFillsBack() {
        let n = 3, name = "보고서"
        let text: LocalizedText = "\(name) 외 \(n)개"
        XCTAssertEqual(text.key, "%@ 외 %@개")
        XCTAssertEqual(tr("\(name) 외 \(n)개"), "보고서 외 3개")
    }

    func testPositionalPlaceholdersReorder() {
        XCTAssertEqual(L10n.fill("%2$@ of %1$@", ["a", "b"]), "b of a")
        XCTAssertEqual(L10n.fill("%@ and %@", ["a"]), "a and ")
    }

    func testEnglishFallsBackToTheKoreanSource() {
        L10n.current = .en
        XCTAssertEqual(tr("번역이 없는 문장 \(1)"), "번역이 없는 문장 1")
    }

    func testEveryTranslationKeepsItsPlaceholders() {
        XCTAssertFalse(L10n.english.isEmpty, "en.json must load from the Core bundle")
        for (ko, en) in L10n.english {
            let plain = { (s: String) in s.components(separatedBy: "%@").count - 1 + s.matches(of: /%\d+\$@/).count }
            XCTAssertEqual(plain(ko), plain(en), "placeholders differ: \(ko) → \(en)")
        }
    }
}
