import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WorkGraphCore

/// 가짜 멀티모달 LLM: write_cards 호출이면 이미지 수만큼 카드를, 아니면 행 배정 답을 돌려준다
final class StubVisionLLM: VisionLLMClient, @unchecked Sendable {
    let modelName = "stub-vision"
    private let lock = NSLock()
    private(set) var visionCalls = 0, imageCounts: [Int] = [], assignUsers: [String] = []
    let assignAnswer: String

    init(assignAnswer: String) { self.assignAnswer = assignAnswer }

    func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult {
        lock.withLock { assignUsers.append(user) }
        return LLMResult(arguments: Data(assignAnswer.utf8), model: modelName, promptTokens: 1, completionTokens: 1, raw: assignAnswer)
    }

    func callFunction(system: String, user: String, images: [(data: Data, mime: String)], detail: String, tool: ToolSpec) async throws -> LLMResult {
        lock.withLock { visionCalls += 1; imageCounts.append(images.count) }
        let cards = (1...max(1, images.count)).map { n in
            ["image": n, "activity": "문서 \(n) 을 읽고 있다", "content": ["제목: 문서 \(n)", "릿지 alpha=0.1"], "kind": "document",
             "entities": ["documents": ["doc\(n).pdf"], "numbers": ["alpha 0.1"]]] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["cards": cards])
        return LLMResult(arguments: data, model: modelName, promptTokens: 1000, completionTokens: 100, raw: String(data: data, encoding: .utf8) ?? "")
    }
}

final class KeyframeSelectorTests: XCTestCase {
    private func row(_ n: Int, _ start: Double, _ dwell: Int, app: String = "Preview", bundle: String = "com.apple.Preview", title: String?, uri: String?, obs: [Int64]) -> ActivityRow {
        ActivityRow(row: n, start: start, end: start + Double(dwell), dwell: dwell, app: app, appBundle: bundle, title: title, uri: uri, type: "Document",
                    projectKey: nil, projectTitle: nil, snippet: nil, observationIds: obs)
    }

    func testSameScreenIsGroupedAcrossRowsAndScrollMakesANewScreen() {
        let rows = [row(1, 0, 60, title: "a.pdf", uri: "file:~/a.pdf", obs: [1, 2]),
                    row(2, 60, 30, app: "Chrome", bundle: "com.google.Chrome", title: "Docs", uri: "https://docs.example/x", obs: [3]),
                    row(3, 90, 40, title: "a.pdf", uri: "file:~/a.pdf", obs: [4]),
                    row(4, 130, 3, app: "Chrome", bundle: "com.google.Chrome", title: "Flash", uri: "https://flash.example", obs: [5]),
                    row(5, 133, 20, app: "loginwindow", bundle: "com.apple.loginwindow", title: nil, uri: nil, obs: [6])]
        let shots: [Int64: KeyframeSelector.Shot] = [
            1: .init(observationId: 1, ts: 0, path: "/s1", hash: 0b0000),
            2: .init(observationId: 2, ts: 30, path: "/s2", hash: 0xFFFF_FFFF_0000_0000),     // 스크롤: 해시가 크게 다름 → 다른 화면
            3: .init(observationId: 3, ts: 60, path: "/s3", hash: 0x1234),
            4: .init(observationId: 4, ts: 90, path: "/s4", hash: 0b0011),                    // 첫 화면으로 돌아옴 (거리 2)
            5: .init(observationId: 5, ts: 130, path: "/s5", hash: 0x9999),
            6: .init(observationId: 6, ts: 133, path: "/s6", hash: 0x7777),
        ]
        let groups = KeyframeSelector.select(rows: rows, shots: shots)
        XCTAssertEqual(groups.count, 3, "3초 본 화면과 잠금 화면은 제외")
        XCTAssertEqual(groups[0].rows, [1, 3], "돌아온 같은 화면은 한 묶음")
        XCTAssertEqual(groups[0].seconds, 70, "행1 절반(30) + 행3 전부(40)")
        XCTAssertEqual(groups[0].observationIds.sorted(), [1, 4])
        XCTAssertEqual(Set(groups.map(\.rows)), [[1, 3], [2], [1]])
        XCTAssertEqual(groups.first { $0.shots.first?.path == "/s2" }?.observationIds, [2])
    }

    func testRepresentativeIsTheMiddleShot() {
        let rows = [row(1, 0, 180, title: "a.pdf", uri: "file:~/a.pdf", obs: [1, 2, 3])]
        let shots: [Int64: KeyframeSelector.Shot] = [1: .init(observationId: 1, ts: 0, path: "/1", hash: 0), 2: .init(observationId: 2, ts: 60, path: "/2", hash: 1),
                                                     3: .init(observationId: 3, ts: 120, path: "/3", hash: 3)]
        XCTAssertEqual(KeyframeSelector.select(rows: rows, shots: shots).first?.representative.path, "/2")
    }
}

final class ScreenCardBatchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wg-cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func jpeg(_ name: String, gray: CGFloat) throws -> String {
        let url = dir.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        context.setFillColor(gray: gray, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return url.path
    }

    func testBatchMakesCardsUsesThemInThePromptAndReusesTheSameScreen() async throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        try await db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        let shot = try jpeg("a.jpg", gray: 0.3)
        func add(_ ts: Double, _ title: String, hash: UInt64?) throws -> Int64 {
            let id = try store.insert(Observation(ts: ts, trigger: "app_activate", appBundle: "com.apple.Preview", appName: "미리보기", windowTitle: title, docPath: "/Users/me/\(title)"))
            if let hash { try store.attachScreen(observationId: id, path: shot, hash: hash) }
            return id
        }
        _ = try add(100, "lecture.pdf", hash: 0xAAAA)
        _ = try add(160, "lecture.pdf", hash: 0xAAAB)                 // 같은 화면 (주기 캡처)
        _ = try add(250, "memo.txt", hash: nil)                       // 사진 없음
        let answer = #"{"tasks":[{"ref":"A","match":"new","title":"강의 복습","task_type":"복습"}],"rows":[{"rows":"1-2","task":"A","resource":true,"reason":"강의자료"}],"work":[{"task":"A","summary":"강의자료를 읽었다","topics":["회귀"]}]}"#
        let llm = StubVisionLLM(assignAnswer: answer)
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { FileManager.default.fileExists(atPath: $0) || $0.hasPrefix("/Users/me") }, clock: { 2_000 })
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("배치 성공해야 함") }

        XCTAssertEqual(llm.visionCalls, 1)
        XCTAssertEqual(llm.imageCounts, [1], "같은 화면 두 장은 대표 한 장으로")
        let user = try XCTUnwrap(llm.assignUsers.last)
        XCTAssertTrue(user.contains("screen: 문서 1 을 읽고 있다"), user)
        XCTAssertTrue(user.contains("· 릿지 alpha=0.1"), user)
        let cards = try ScreenCardStore(db).cards(from: 0, to: 10_000)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].windowTitle, "lecture.pdf")
        XCTAssertTrue(cards[0].entities.contains("doc1.pdf"))
        let linked = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE card_id = ?", arguments: [cards[0].id!]) }
        XCTAssertEqual(linked, 2)
        // FTS: 한국어 부분 문자열로 찾힌다 (나중에 LLM 검색이 쓸 색인)
        let hit = try await db.writer.read { try Int64.fetchOne($0, sql: "SELECT rowid FROM screen_cards_fts WHERE screen_cards_fts MATCH '\"읽고 있\"'") }
        XCTAssertEqual(hit, cards[0].id)

        // 다음 배치: 같은 화면으로 돌아오면 LLM 을 다시 부르지 않고 카드를 재사용
        _ = try add(400, "lecture.pdf", hash: 0xAAAA)
        _ = try add(460, "lecture.pdf", hash: 0xAAAA)
        _ = try add(700, "memo.txt", hash: nil)
        let reuseBatcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { FileManager.default.fileExists(atPath: $0) || $0.hasPrefix("/Users/me") }, clock: { 3_000 })
        guard case .ok = await reuseBatcher.runIfDue(force: true) else { return XCTFail("두 번째 배치 성공해야 함") }
        XCTAssertEqual(llm.visionCalls, 1, "같은 화면은 재사용")
        XCTAssertEqual(try ScreenCardStore(db).cards(from: 0, to: 10_000).count, 1)
        XCTAssertEqual(try ScreenCardStore(db).card(id: cards[0].id!)?.tsEnd, 550, "재사용하면 카드의 끝 시각이 늘어난다 (460 + 체류 상한 90)")
    }

    func testReprocessingKeepsExistingCardsInsteadOfMakingNewOnes() async throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        try await db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        let shot = try jpeg("c.jpg", gray: 0.4)
        for (ts, hash) in [(100.0, UInt64(0x0F0F)), (160, 0xFFFF_0000_FFFF_0000)] {        // 같은 창에서 스크롤: 두 화면
            let id = try store.insert(Observation(ts: ts, trigger: "app_activate", appBundle: "com.apple.Preview", appName: "미리보기", windowTitle: "a.pdf"))
            try store.attachScreen(observationId: id, path: shot, hash: hash)
        }
        _ = try store.insert(Observation(ts: 300, trigger: "app_activate", appBundle: "com.apple.Preview", appName: "미리보기", windowTitle: "b.txt"))
        let answer = #"{"tasks":[{"ref":"A","match":"new","title":"읽기","task_type":"복습","goal":"읽기"}],"rows":[{"rows":"1-2","task":"A","resource":true,"reason":"r"}],"work":[]}"#
        let llm = StubVisionLLM(assignAnswer: answer)
        let make = { OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { FileManager.default.fileExists(atPath: $0) }, clock: { 2_000 }) }
        guard case .ok = await make().runIfDue(force: true) else { return XCTFail("첫 배치") }
        let first = try ScreenCardStore(db).cards(from: 0, to: 10_000).count
        XCTAssertEqual(llm.visionCalls, 1)
        // 재생성처럼 판정만 지우고 다시 돈다 (card_id 는 남는다)
        try await db.writer.write { try $0.execute(sql: "UPDATE observations SET batch_id = NULL, task_id = NULL") }
        guard case .ok = await make().runIfDue(force: true) else { return XCTFail("두 번째 배치") }
        XCTAssertEqual(llm.visionCalls, 1, "이미 연결된 카드를 쓰고 LLM 을 다시 부르지 않는다")
        XCTAssertEqual(try ScreenCardStore(db).cards(from: 0, to: 10_000).count, first, "카드가 늘지 않는다")
    }

    func testNonVisionLLMMakesNoCards() async throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        let shot = try jpeg("b.jpg", gray: 0.5)
        let id = try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.apple.Preview", appName: "미리보기", windowTitle: "a.pdf"))
        try store.attachScreen(observationId: id, path: shot, hash: 1)
        _ = try store.insert(Observation(ts: 200, trigger: "app_activate", appBundle: "com.apple.Preview", appName: "미리보기", windowTitle: "b.pdf"))
        let llm = StubLLM([.success(#"{"tasks":[],"rows":[{"rows":"1-2","task":"off"}],"work":[]}"#)])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { FileManager.default.fileExists(atPath: $0) }, clock: { 2_000 })
        _ = await batcher.runIfDue(force: true)
        XCTAssertTrue(try ScreenCardStore(db).cards(from: 0, to: 10_000).isEmpty)
    }
}
