import XCTest
@testable import WorkGraphCore

/// 파일 > 지난 기록: 결정한 제안을 최근 것부터 쪽마다 꺼낸다 (대기 중인 제안은 빼고)
final class FileSuggestionStoreTests: XCTestCase {
    private func suggestion(_ ts: Int, status: String) -> FileSuggestion {
        FileSuggestion(ts: Double(ts), path: "/tmp/\(ts).pdf", fileName: "\(ts).pdf", originUrl: nil, suggestedFolder: "/tmp/학교",
                       confidence: 0.9, reason: nil, source: "llm", status: status)
    }

    func testDecidedSuggestionsComeInPagesNewestFirst() throws {
        let store = FileSuggestionStore(try WGDatabase.inMemory())
        for ts in 1...70 { try store.insert(suggestion(ts, status: ts % 10 == 0 ? "ignored" : "moved")) }
        for ts in 71...73 { try store.insert(suggestion(ts, status: "pending")) }

        XCTAssertEqual(try store.decidedCount(), 70)
        XCTAssertEqual(try store.decided(limit: 20, offset: 0).map(\.ts), (51...70).reversed().map(Double.init))
        XCTAssertEqual(try store.decided(limit: 20, offset: 60).map(\.ts), (1...10).reversed().map(Double.init), "60개 넘는 옛 기록도 꺼낼 수 있다")
        XCTAssertEqual(try store.pending().count, 3)
    }
}
