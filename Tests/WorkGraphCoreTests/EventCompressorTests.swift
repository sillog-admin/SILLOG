import XCTest
@testable import WorkGraphCore

final class EventCompressorTests: XCTestCase {
    private func obs(_ id: Int64, _ ts: Double, app: String, title: String? = nil, url: String? = nil, textId: Int64? = nil) -> Observation {
        Observation(id: id, ts: ts, trigger: "test", appBundle: "bundle.\(app)", appName: app, windowTitle: title, url: url, textId: textId)
    }

    private func compress(_ observations: [Observation], idle: [IdleSpan] = [], texts: [Int64: String] = [:], windowEnd: Double,
                          maxRows: Int = 150, snippetChars: Int = 300, snippetTopN: Int = 12) -> [ActivityRow] {
        EventCompressor.compress(observations, idle: idle, texts: texts, windowEnd: windowEnd, home: "/Users/me",
                                 fileExists: { _ in false }, maxRows: maxRows, maxGap: 90,
                                 snippetChars: snippetChars, snippetTopN: snippetTopN)
    }

    func testMergesConsecutiveSameContext() {
        let rows = compress([obs(1, 0, app: "A", title: "x"), obs(2, 30, app: "A", title: "x"), obs(3, 60, app: "B")], windowEnd: 100)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].dwell, 60)
        XCTAssertEqual(rows[0].observationIds, [1, 2])
        XCTAssertEqual(rows[0].start, 0)
        XCTAssertEqual(rows[0].end, 60)
        XCTAssertEqual(rows[1].dwell, 40)
        XCTAssertEqual(rows.map(\.row), [1, 2])
    }

    func testShortRowIsAbsorbedAndNeighboursMerge() {
        let rows = compress([obs(1, 0, app: "A"), obs(2, 50, app: "B"), obs(3, 51, app: "A")], windowEnd: 80)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].app, "A")
        XCTAssertEqual(rows[0].dwell, 80)
        XCTAssertEqual(rows[0].observationIds, [1, 2, 3])
    }

    func testIdleTimeIsSubtracted() {
        let rows = compress([obs(1, 0, app: "A"), obs(2, 80, app: "B")], idle: [IdleSpan(startTs: 20, endTs: 50)], windowEnd: 90)
        XCTAssertEqual(rows[0].dwell, 50)
        XCTAssertEqual(rows[1].dwell, 10)
    }

    func testGapIsCappedWhenCollectorWasNotRunning() {
        let rows = compress([obs(1, 0, app: "A"), obs(2, 1000, app: "B")], windowEnd: 1010)
        XCTAssertEqual(rows[0].dwell, 90)
        XCTAssertEqual(rows[1].dwell, 10)
    }

    func testRowsAreClassified() {
        let rows = compress([obs(1, 0, app: "Chrome", title: "Card - shadcn/ui - Google Chrome", url: "https://ui.shadcn.com/docs/components/card#x")],
                            windowEnd: 30)
        XCTAssertEqual(rows[0].uri, "https://ui.shadcn.com/docs/components/card")
        XCTAssertEqual(rows[0].type, "Documentation")
        XCTAssertEqual(rows[0].title, "Card - shadcn/ui")
    }

    func testSnippetOnlyForTopDwellRows() {
        let rows = compress([obs(1, 0, app: "A", textId: 1), obs(2, 10, app: "B", textId: 2), obs(3, 70, app: "C", textId: 3)],
                            texts: [1: "short  one", 2: "the   longest\n\ndwell row text", 3: "third"],
                            windowEnd: 80, snippetChars: 11, snippetTopN: 1)
        XCTAssertNil(rows[0].snippet)
        XCTAssertEqual(rows[1].snippet, "the longest")
        XCTAssertNil(rows[2].snippet)
    }

    func testMaxRowsKeepsEarliestRowsOnly() {
        let observations = (0..<5).map { obs(Int64($0 + 1), Double($0) * 10, app: "App\($0)") }
        let rows = compress(observations, windowEnd: 50, maxRows: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.flatMap(\.observationIds), [1, 2, 3])
    }

    func testEmptyInput() {
        XCTAssertTrue(compress([], windowEnd: 10).isEmpty)
    }
}
