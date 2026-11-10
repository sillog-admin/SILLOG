import XCTest
@testable import WorkGraphCore

final class FolderSuggesterTests: XCTestCase {
    private var root: URL!
    private var db: WGDatabase!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wg-suggest-\(UUID().uuidString)")
        for (path, files) in [("Desktop/study/ai 기초수학", ["week1.pdf", "week2.pdf"]), ("Desktop/study/자료구조", ["ch1.pdf"]), ("Downloads", [])] {
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in files { try Data("x".utf8).write(to: dir.appendingPathComponent(file)) }
        }
        db = try WGDatabase.inMemory()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var index: FolderIndex { FolderIndex.scan(roots: [root.appendingPathComponent("Desktop").path], home: root.path) }

    private func download(_ name: String) throws -> String {
        let path = root.appendingPathComponent("Downloads/\(name)").path
        try Data("pdf".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func testLLMPicksAmongRealCandidatesAndSuggestionIsStored() async throws {
        let mathFolder = root.appendingPathComponent("Desktop/study/ai 기초수학").path
        let llm = StubLLM([.success(#"{"folder":"\#(mathFolder)","confidence":0.88,"reason":"AI기초수학 강의자료라 같은 과목 폴더"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path, minConfidence: 0.6)
        let path = try download("week3_linear_algebra.pdf")
        let suggestion = try await suggester.suggest(filePath: path, originURL: "https://lms.example.com/course/1234/file/99", index: index,
                                                     context: FolderSuggester.Context(recentTitles: ["AI기초수학 3주차 강의자료 - LMS"],
                                                                                      screenText: "AI기초수학 (월 3,4교시) 3주차 강의자료 벡터공간과 내적.pdf 다운로드", openTasks: [], now: 1_000))
        let result = try XCTUnwrap(suggestion)
        XCTAssertEqual(result.suggestedFolder, mathFolder)
        XCTAssertEqual(result.status, "pending")
        XCTAssertEqual(result.reason, "AI기초수학 강의자료라 같은 과목 폴더")
        XCTAssertTrue(llm.lastUser.contains("week3_linear_algebra.pdf"))
        XCTAssertTrue(llm.lastUser.contains("lms.example.com"))
        XCTAssertTrue(llm.lastUser.contains("~/Desktop/study/ai 기초수학"))
        XCTAssertTrue(llm.lastUser.contains("week1.pdf"))
        XCTAssertTrue(llm.lastUser.contains("TEXT ON SCREEN WHEN THE FILE ARRIVED: AI기초수학 (월 3,4교시)"))
        XCTAssertEqual(try FileSuggestionStore(db).pending().count, 1)
    }

    func testLowConfidenceOrNoneMeansNoSuggestion() async throws {
        let llm = StubLLM([.success(#"{"folder":"","confidence":0.2,"reason":"모르겠음"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path)
        let suggestion = try await suggester.suggest(filePath: try download("random.bin"), originURL: nil, index: index,
                                                     context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 1_000))
        XCTAssertNil(suggestion)
        XCTAssertTrue(try FileSuggestionStore(db).pending().isEmpty)
    }

    func testLLMCannotInventAFolder() async throws {
        let llm = StubLLM([.success(#"{"folder":"/nowhere/made-up","confidence":0.95,"reason":"x"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path)
        let suggestion = try await suggester.suggest(filePath: try download("a.pdf"), originURL: nil, index: index,
                                                     context: FolderSuggester.Context(recentTitles: ["자료구조"], openTasks: [], now: 1_000))
        XCTAssertNil(suggestion, "후보에 없는 경로는 버린다")
    }

    func testAcceptMovesFileLearnsAndCanUndo() async throws {
        let mathFolder = root.appendingPathComponent("Desktop/study/ai 기초수학").path
        let llm = StubLLM([.success(#"{"folder":"\#(mathFolder)","confidence":0.9,"reason":"r"}"#),
                           .success(#"{"folder":"\#(mathFolder)","confidence":0.9,"reason":"r2"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path)
        let path = try download("week3.pdf")
        let suggestionMaybe = try await suggester.suggest(filePath: path, originURL: "https://lms.example.com/course/1234/file/99", index: index,
                                                                   context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 1_000))
        let suggestion = try XCTUnwrap(suggestionMaybe)
        let moved = try suggester.accept(id: suggestion.id!, now: 1_100)
        XCTAssertEqual(moved, mathFolder + "/week3.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try FileSuggestionStore(db).suggestion(id: suggestion.id!)?.status, "moved")

        // 같은 페이지에서 받은 다음 파일도 LLM 이 새로 판단한다. 전에 옮긴 곳은 힌트로만 들어간다.
        let againMaybe = try await suggester.suggest(filePath: try download("week4.pdf"), originURL: "https://lms.example.com/course/1234/file/100", index: index,
                                                              context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 2_000))
        let again = try XCTUnwrap(againMaybe)
        XCTAssertEqual(again.source, "llm")
        XCTAssertEqual(llm.calls, 2)
        XCTAssertTrue(llm.lastUser.contains("EARLIER THE USER MOVED a file from the same page TO: ~/Desktop/study/ai 기초수학 (hint, not a rule)"), llm.lastUser)

        // 이름이 겹치면 덮어쓰지 않고 번호를 붙인다
        _ = try download("week3.pdf")
        let clash = try suggester.move(from: root.appendingPathComponent("Downloads/week3.pdf").path, to: mathFolder)
        XCTAssertEqual((clash as NSString).lastPathComponent, "week3 (2).pdf")

        // 되돌리기
        let restored = try suggester.undo(id: suggestion.id!, now: 1_200)
        XCTAssertEqual(restored, path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try FileSuggestionStore(db).suggestion(id: suggestion.id!)?.status, "undone")
    }

    func testTaskRuleIsOnlyAHintToTheLLM() async throws {
        let mathFolder = root.appendingPathComponent("Desktop/study/ai 기초수학").path
        let dsFolder = root.appendingPathComponent("Desktop/study/자료구조").path
        let llm = StubLLM([.success(#"{"folder":"\#(mathFolder)","confidence":0.9,"reason":"r"}"#),
                           .success(#"{"folder":"\#(dsFolder)","confidence":0.8,"reason":"다른 과목"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path)
        let firstMaybe = try await suggester.suggest(filePath: try download("a.pdf"), originURL: nil, index: index,
                                                              context: FolderSuggester.Context(recentTitles: [], openTasks: [], currentTaskKey: "t_1", now: 1_000))
        let first = try XCTUnwrap(firstMaybe)
        _ = try suggester.accept(id: first.id!, now: 1_100)
        // 같은 업무 중 받은 다음 파일: 규칙으로 바로 정하지 않고 LLM 이 힌트를 보고 고른다
        let secondMaybe = try await suggester.suggest(filePath: try download("b.pdf"), originURL: nil, index: index,
                                                               context: FolderSuggester.Context(recentTitles: [], openTasks: [], currentTaskKey: "t_1", now: 2_000))
        let second = try XCTUnwrap(secondMaybe)
        XCTAssertEqual(llm.calls, 2)
        XCTAssertEqual(second.source, "llm")
        XCTAssertEqual(second.suggestedFolder, dsFolder)
        XCTAssertTrue(llm.lastUser.contains("EARLIER THE USER MOVED a file downloaded while working on the same task TO: ~/Desktop/study/ai 기초수학"))
    }

    func testUndoneFileIsNotSuggestedAgainRightAway() async throws {
        let mathFolder = root.appendingPathComponent("Desktop/study/ai 기초수학").path
        let llm = StubLLM([.success(#"{"folder":"\#(mathFolder)","confidence":0.9,"reason":"r"}"#),
                           .success(#"{"folder":"\#(mathFolder)","confidence":0.9,"reason":"r"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path)
        let path = try download("x.pdf")
        let firstMaybe = try await suggester.suggest(filePath: path, originURL: nil, index: index, context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 1_000))
        let first = try XCTUnwrap(firstMaybe)
        _ = try suggester.accept(id: first.id!, now: 1_100)
        _ = try suggester.undo(id: first.id!, now: 1_200)
        // 되돌린 직후 (다운로드 폴더에 다시 나타남): 제안하지 않는다
        let soon = try await suggester.suggest(filePath: path, originURL: nil, index: index, context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 1_300))
        XCTAssertNil(soon)
        XCTAssertEqual(llm.calls, 1)
        // 한참 뒤에 다시 받으면 새로 판단
        let later = try await suggester.suggest(filePath: path, originURL: nil, index: index, context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 5_000))
        XCTAssertNotNil(later)
    }

    func testPendingSuggestionClosesWhenTheFileIsGone() async throws {
        let mathFolder = root.appendingPathComponent("Desktop/study/ai 기초수학").path
        let llm = StubLLM([.success(#"{"folder":"\#(mathFolder)","confidence":0.9,"reason":"r"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path)
        let path = try download("y.pdf")
        let pendingMaybe = try await suggester.suggest(filePath: path, originURL: nil, index: index, context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 1_000))
        let pending = try XCTUnwrap(pendingMaybe)
        try FileManager.default.removeItem(atPath: path)                 // 사용자가 Finder 에서 직접 옮김
        let closed = try FileSuggestionStore(db).closeGone(now: 1_500, fileExists: { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(closed, [pending.id!])
        XCTAssertEqual(try FileSuggestionStore(db).suggestion(id: pending.id!)?.status, "gone")
        XCTAssertTrue(try FileSuggestionStore(db).pending().isEmpty)
    }

    func testRejectWithChosenFolderTeachesThatFolder() async throws {
        let mathFolder = root.appendingPathComponent("Desktop/study/ai 기초수학").path
        let dsFolder = root.appendingPathComponent("Desktop/study/자료구조").path
        let llm = StubLLM([.success(#"{"folder":"\#(mathFolder)","confidence":0.9,"reason":"r"}"#),
                           .success(#"{"folder":"\#(dsFolder)","confidence":0.9,"reason":"r"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path)
        let suggestionMaybe = try await suggester.suggest(filePath: try download("ch2.pdf"), originURL: "https://lms.example.com/course/777/file/1", index: index,
                                                                   context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 1_000))
        let suggestion = try XCTUnwrap(suggestionMaybe)
        let moved = try suggester.rejectAndMove(id: suggestion.id!, to: dsFolder, now: 1_100)
        XCTAssertEqual((moved as NSString).deletingLastPathComponent, dsFolder)
        XCTAssertEqual(try FileSuggestionStore(db).suggestion(id: suggestion.id!)?.status, "moved")
        XCTAssertEqual(try FileSuggestionStore(db).suggestion(id: suggestion.id!)?.movedTo, moved)
        let nextMaybe = try await suggester.suggest(filePath: try download("ch3.pdf"), originURL: "https://lms.example.com/course/777/file/2", index: index,
                                                             context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 2_000))
        let next = try XCTUnwrap(nextMaybe)
        XCTAssertEqual(next.suggestedFolder, dsFolder)
        XCTAssertTrue(llm.lastUser.contains("EARLIER THE USER MOVED a file from the same page TO: ~/Desktop/study/자료구조"), "사용자가 고른 폴더가 힌트가 된다")
    }

    private func recordingText(_ name: String) throws -> String {
        let url = root.appendingPathComponent("Documents/SILLOG 녹음/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# 녹음".utf8).write(to: url)
        return url.path
    }

    func testRecordingTranscriptIsFiledByWhatWasSaid() async throws {
        let dsFolder = root.appendingPathComponent("Desktop/study/자료구조").path
        let llm = StubLLM([.success(#"{"folder":"\#(dsFolder)","confidence":0.9,"reason":"자료구조 강의 녹음"}"#)])
        let suggester = FolderSuggester(db: db, llm: llm, home: root.path)
        let excerpt = "연결 리스트를 설명한 강의.\n오늘은 자료구조 3주차, 연결 리스트의 삽입과 삭제를 봅니다."
        let suggestion = try await suggester.suggest(filePath: try recordingText("2026-10-10 녹음 15-32.md"), originURL: nil, index: index,
                                                     context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 1_000,
                                                                                      contentExcerpt: excerpt, kind: .recording))
        XCTAssertEqual(try XCTUnwrap(suggestion).suggestedFolder, dsFolder)
        XCTAssertTrue(llm.lastSystem.contains("voice recording"))
        XCTAssertFalse(llm.lastSystem.contains("newly downloaded document"))
        XCTAssertTrue(llm.lastUser.contains("THIS FILE IS: the transcript of a voice recording the user just made"))
        XCTAssertTrue(llm.lastUser.contains("CONTENT (transcript excerpt): 연결 리스트를 설명한 강의. 오늘은 자료구조 3주차"))
        XCTAssertTrue(llm.lastUser.contains("~/Desktop/study/자료구조"), "내용 발췌가 후보를 끌어올린다")
        XCTAssertFalse(llm.lastUser.contains("ai 기초수학"), "내용과 맞지 않는 폴더는 후보에 없다")
    }

    func testARecordingNamedOnlyByDateHasNoCandidatesWithoutAnExcerpt() async throws {
        let llm = StubLLM([])
        let suggestion = try await FolderSuggester(db: db, llm: llm, home: root.path)
            .suggest(filePath: try recordingText("2026-10-10 녹음 15-32.md"), originURL: nil, index: index,
                     context: FolderSuggester.Context(recentTitles: [], openTasks: [], now: 1_000, kind: .recording))
        XCTAssertNil(suggestion)
        XCTAssertEqual(llm.calls, 0)
    }

    func testDownloadsKeepTheDownloadWording() async throws {
        let mathFolder = root.appendingPathComponent("Desktop/study/ai 기초수학").path
        let llm = StubLLM([.success(#"{"folder":"\#(mathFolder)","confidence":0.9,"reason":"r"}"#)])
        _ = try await FolderSuggester(db: db, llm: llm, home: root.path)
            .suggest(filePath: try download("week4.pdf"), originURL: nil, index: index,
                     context: FolderSuggester.Context(recentTitles: ["AI기초수학"], openTasks: [], now: 1_000))
        XCTAssertTrue(llm.lastSystem.contains("newly downloaded document"))
        XCTAssertFalse(llm.lastUser.contains("CONTENT (transcript excerpt)"))
        XCTAssertFalse(llm.lastUser.contains("THIS FILE IS"))
    }
}
