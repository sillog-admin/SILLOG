import XCTest
@testable import SillogCore

final class DictationDraftTests: XCTestCase {
    func testPartialsReplaceEachOtherAtTheCaretAndUtterancesAccumulate() {
        var draft = DictationDraft(draft: "회의록을정리해 줘", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(draft.hear("어제", utteranceEnded: false, isFinal: false), "회의록 어제 을정리해 줘")
        XCTAssertEqual(draft.hear("어제 회의", utteranceEnded: true, isFinal: false), "회의록 어제 회의 을정리해 줘")
        XCTAssertEqual(draft.hear("요약", utteranceEnded: false, isFinal: false), "회의록 어제 회의 요약 을정리해 줘")
        XCTAssertEqual(draft.hear("요약.", utteranceEnded: false, isFinal: true), "회의록 어제 회의 요약. 을정리해 줘")
    }

    func testNoSelectionAppendsAndSelectedTextIsReplaced() {
        XCTAssertEqual(DictationDraft(draft: "안녕 ", selection: nil).merged("하세요"), "안녕 하세요")
        XCTAssertEqual(DictationDraft(draft: "", selection: nil).merged(" hello "), "hello")
        XCTAssertEqual(DictationDraft(draft: "a bad day", selection: NSRange(location: 2, length: 3)).merged("good"), "a good day")
        XCTAssertEqual(DictationDraft(draft: "short", selection: NSRange(location: 9, length: 0)).merged("x"), "short x")
        XCTAssertEqual(DictationDraft(draft: "keep", selection: nil).merged("  "), "keep")
    }
}
