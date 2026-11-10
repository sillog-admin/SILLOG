import AppKit
import SwiftUI
import Vision
import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 파일 > 지난 기록은 20줄씩 쪽으로 나눠 ‹ 1 2 3 › 로 넘긴다 (예전에는 최근 60개만 불러와 옛 기록이 안 보였다). 대기 중인 제안은 쪽과 상관없이 다 보인다
@MainActor
final class FileHistoryPagesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wg-file-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// 결정한 제안 decided 개(기록1 이 가장 오래됨)와 대기 중인 제안 pending 개 (대기 중인 파일은 실제로 있어야 '사라짐'으로 닫히지 않는다)
    private func state(decided: Int, pending: Int = 0) throws -> AppState {
        let db = try WGDatabase.inMemory()
        let store = FileSuggestionStore(db)
        for index in 1...decided {
            try store.insert(FileSuggestion(ts: Double(index), path: "/tmp/기록\(index).pdf", fileName: "기록\(index).pdf", originUrl: nil,
                                            suggestedFolder: "/tmp/학교", confidence: 0.9, reason: nil, source: "llm", status: "moved",
                                            movedTo: "/tmp/학교/기록\(index).pdf", decidedAt: Double(index)))
        }
        for index in 0..<pending {
            let file = folder.appendingPathComponent("새 파일\(index).pdf")
            try Data("pdf".utf8).write(to: file)
            try store.insert(FileSuggestion(ts: Double(10_000 + index), path: file.path, fileName: file.lastPathComponent, originUrl: nil,
                                            suggestedFolder: "/tmp/학교", confidence: 0.9, reason: nil, source: "llm"))
        }
        return AppState(preview: { $0.phase = .ready }, database: db)
    }

    private func history(_ state: AppState) -> [FileSuggestion] { state.fileSuggestions.filter { $0.status != "pending" } }

    func testHistoryComesTwentyAtATimeAndOldRecordsAreReachable() throws {
        let state = try state(decided: 70, pending: 2)
        state.refreshFileSuggestions()
        XCTAssertEqual(state.fileHistoryTotal, 70)
        XCTAssertEqual(state.fileSuggestions.filter { $0.status == "pending" }.count, 2, "대기 중인 제안은 다 보인다")
        XCTAssertEqual(history(state).count, 20)
        XCTAssertEqual(history(state).first?.fileName, "기록70.pdf", "최근 것부터")

        state.showFileHistoryPage(3)
        XCTAssertEqual(history(state).count, 10)
        XCTAssertEqual(history(state).last?.fileName, "기록1.pdf", "60개 넘는 옛 기록도 마지막 쪽에서 보인다")
        XCTAssertEqual(state.fileSuggestions.filter { $0.status == "pending" }.count, 2)
    }

    func testAPageBeyondTheEndShowsTheLastPage() throws {
        let state = try state(decided: 25)
        state.showFileHistoryPage(9)
        XCTAssertEqual(state.fileHistoryPage, 1)
        XCTAssertEqual(history(state).count, 5)
    }

    func testPageNumbersShowEveryPageOrAWindowAroundTheCurrentOne() {
        XCTAssertEqual(PageNumbers.numbers(current: 0, pages: 3), [0, 1, 2])
        XCTAssertEqual(PageNumbers.numbers(current: 0, pages: 12), [0, 1, 2, 3, nil, 11])
        XCTAssertEqual(PageNumbers.numbers(current: 5, pages: 12), [0, nil, 4, 5, 6, nil, 11])
        XCTAssertEqual(PageNumbers.numbers(current: 3, pages: 12), [0, 1, 2, 3, 4, nil, 11], "한 쪽만 빠지면 '…' 대신 그 번호")
        XCTAssertEqual(PageNumbers.numbers(current: 11, pages: 12), [0, nil, 8, 9, 10, 11])
    }

    /// 지난 기록 45개 중 첫 쪽을 그린 지난 기록 탭 (줄은 3개만 넣는다)
    private func historyScreen() -> NSView {
        let rows = (1...3).map { index in                                  // 옮김(되돌리기 단추 있음)과 무시(단추 없음)가 섞인 줄
            FileSuggestion(id: Int64(index), ts: 0, path: "/tmp/보고서\(index).pdf", fileName: "보고서.pdf", originUrl: nil, suggestedFolder: "/tmp/학교",
                           confidence: 0.9, reason: nil, source: "llm", status: index == 2 ? "ignored" : "moved", movedTo: "/tmp/학교/보고서.pdf")
        }
        let state = AppState(preview: { s in s.phase = .ready; s.fileSuggestions = rows; s.fileHistoryTotal = 45 })
        let host = NSHostingView(rootView: AnyView(FileHistoryView().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return host
    }

    // 표 머리와 모든 줄의 칸이 같은 자리에 있다 (되돌리기 단추가 없는 머리·무시 줄은 그 칸이 자리를 안 차지해 오른쪽으로 밀렸었다)
    func testTheHeaderColumnsLineUpWithTheRows() throws {
        let host = historyScreen()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(rep.cgImage)).perform([request])
        let boxes = (request.results ?? []).compactMap { item in item.topCandidates(1).first.map { ($0.string, item.boundingBox) } }
        let header = try XCTUnwrap(boxes.first { $0.0 == "폴더" }, "\(boxes.map(\.0))").1
        let cells = boxes.filter { $0.0.hasSuffix("학교") }.map(\.1)            // "/tmp/학교" (tmp 는 Amp 로 읽기도 한다)
        XCTAssertEqual(cells.count, 3, "\(boxes.map(\.0))")
        for cell in cells { XCTAssertEqual(cell.minX, header.minX, accuracy: 0.01, "머리 '폴더'와 줄마다의 폴더가 같은 x 에서 시작해야 한다") }
    }

    // 지난 기록 머리에 전체 개수, 표 아래에 쪽 번호 ‹ 1 2 3 ›
    func testTheHistoryShowsItsCountAndPageNumbers() {
        let lines = OnboardingOverlayTests.recognizedText(historyScreen()).components(separatedBy: "\n").map { $0.filter { !$0.isWhitespace } }
        let text = lines.joined()
        XCTAssertTrue(text.contains("지난기록45"), "머리에 전체 개수: \(text)")
        // 45개면 20줄씩 3쪽: 맨 아래 쪽 번호 (지금 쪽 1 은 바탕 위라 글자 인식이 놓치기도 하고, ‹ › 는 다른 글자로 읽기도 한다)
        XCTAssertTrue(lines.contains { $0.hasSuffix("23") || $0.contains("23>") || $0 == "3" }, "\(lines)")
    }
}

/// 5초마다 도는 새로 고침은 바뀐 것이 없으면 화면을 다시 그리게 하지 않는다 (파일 화면은 다시 그릴 때마다 10ms 넘게 걸려 끊겨 보였다)
@MainActor
final class RefreshQuietTests: XCTestCase {
    func testARefreshWithNothingNewDoesNotRedrawTheWindow() throws {
        _ = NSApplication.shared                                          // 독 배지(NSApp)를 쓴다
        let db = try WGDatabase.inMemory()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        state.refreshTasks()
        state.refresh()
        var changes = 0
        let watch = state.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        state.refresh()
        XCTAssertEqual(changes, 0, "바뀐 값이 없으면 @Published 를 건드리지 않는다")
    }
}
