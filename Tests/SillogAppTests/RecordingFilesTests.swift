import AppKit
import XCTest
@testable import SillogApp
@testable import SillogCore

/// 받아쓴 글 .md 를 파일 탭·알림에서 옮기면 녹음 기록이 따라가고, 앱 번들은 권한 사용 문구를 갖는다
@MainActor
final class RecordingFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wg-recording-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testAcceptingAndUndoingTheSuggestionMovesTheRecordingText() throws {
        let db = try SillogDatabase.inMemory()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        let source = folder.appendingPathComponent("SILLOG 녹음"), target = folder.appendingPathComponent("학교/자료구조")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let md = source.appendingPathComponent("2026-10-10 자료구조 3주차 강의.md")
        try Data("# 자료구조 3주차 강의".utf8).write(to: md)
        let recording = try RecordingStore(db).insert(Recording(startedAt: 1_000, endedAt: 1_095, duration: 95, audioPath: "/tmp/x.m4a",
                                                                 textPath: md.path, transcript: "문장", status: .ready))
        let suggestion = try FileSuggestionStore(db).insert(FileSuggestion(ts: 1_100, path: md.path, fileName: md.lastPathComponent, originUrl: nil,
                                                                           suggestedFolder: target.path, confidence: 0.9, reason: "같은 과목", source: "llm"))
        state.suggester = FolderSuggester(db: db, llm: NamingLLM(), home: folder.path)

        state.acceptSuggestion(suggestion)
        let moved = target.appendingPathComponent(md.lastPathComponent).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        XCTAssertEqual(try RecordingStore(db).find(id: recording.id!)?.textPath, moved)

        state.undoSuggestion(try XCTUnwrap(FileSuggestionStore(db).suggestion(id: suggestion.id!)))
        XCTAssertEqual(try RecordingStore(db).find(id: recording.id!)?.textPath, md.path)
    }

    func testAppBundleDeclaresMicrophoneSpeechAndDocumentsUsage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription", "NSDocumentsFolderUsageDescription"] {
            XCTAssertTrue(script.contains("<key>\(key)</key>"), "\(key) 가 없으면 권한을 물을 때 시스템이 앱을 끝낸다")
        }
    }
}
