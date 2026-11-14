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

    func testNamesFitTheLanguageByScript() {
        XCTAssertTrue(AppLanguage.ko.fitsScript("SILLOG 온보딩"))
        XCTAssertFalse(AppLanguage.ko.fitsScript("Maintain the SILLOG codebase"))
        XCTAssertTrue(AppLanguage.en.fitsScript("Maintain the SILLOG codebase"))
        XCTAssertFalse(AppLanguage.en.fitsScript("온보딩 개편"))
    }

    /// Tool schemas are written in Korean; they must still ask for text in the app language.
    func testGeneratedTextIsAskedForInTheAppLanguage() throws {
        func schemas() throws -> [(name: String, text: String)] {
            try [StageTool.classify, StageTool.assign, StageTool.describe, AssignmentSchema.tool,
                 TaskMerger.tool, ThemeStep.tool, DigestPrompt.tool, EventFinder.tool]
                .map { ($0.name, String(decoding: try JSONEncoder().encode($0.parameters), as: UTF8.self)) }
        }
        for schema in try schemas() { XCTAssertTrue(schema.text.contains("한국어"), schema.name) }
        XCTAssertFalse(StagePrompt.describeSystem.contains("examples below are Korean"))

        L10n.current = .en
        for schema in try schemas() {
            XCTAssertFalse(schema.text.contains("한국어"), schema.name)
            XCTAssertTrue(schema.text.contains("영어"), schema.name)
        }
        XCTAssertTrue(StagePrompt.describeSystem.contains("write the summary in English"))
    }

    /// Screens translate these stored Korean names with `L10n.tr(key:)`.
    func testEveryStoredTypeNameHasAnEnglishName() {
        let names = (TBox.taskTypes + TBox.resourceTypes).map(\.name) + NodeDetailBuilder.kindNames.values
        for name in names where name.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
            XCTAssertNotNil(L10n.english[name], name)
        }
    }

    func testEveryTranslationKeepsItsPlaceholders() {
        XCTAssertFalse(L10n.english.isEmpty, "en.json must load from the Core bundle")
        for (ko, en) in L10n.english {
            let plain = { (s: String) in s.components(separatedBy: "%@").count + s.components(separatedBy: "$@").count - 2 }
            XCTAssertEqual(plain(ko), plain(en), "placeholders differ: \(ko) → \(en)")
        }
    }
}
