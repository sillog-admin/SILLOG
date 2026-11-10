import AppKit
import SwiftUI
import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 보관함의 '녹음': 목록 줄 문구, 상세, 7일 안내, 없어진 받아쓴 글 파일
@MainActor
final class RecordingLibraryTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private var folder: URL!

    /// 2026-10-10 15:32 (서울)
    private var start: Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 32))!.timeIntervalSince1970
    }

    override func setUpWithError() throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wg-recording-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func ready(textPath: String?, audioPath: String = "/없음/7.m4a", readyAt: Double = 0) -> Recording {
        Recording(id: 7, startedAt: start, endedAt: start + 3_130, duration: 3_130, audioPath: audioPath, textPath: textPath,
                  title: "자료구조 3주차 강의", summary: "연결 리스트를 설명한 강의.", transcript: "오늘은 연결 리스트를 봅니다.\n노드는 값을 가집니다.",
                  status: .ready, readyAt: readyAt)
    }

    private func render<V: View>(_ view: V, size: CGSize) -> String {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
    }

    func testListRowShowsDateLengthAndFolderOrWhatHappened() {
        let home = "/Users/me"
        XCTAssertEqual(RecordingDetail.subtitle(ready(textPath: "/Users/me/Documents/학교/자료구조/강의.md"), home: home, timeZone: seoul),
                       "10월 10일 15:32  52분 10초  문서 / 학교 / 자료구조")
        var failed = ready(textPath: nil)
        failed.status = .failed
        XCTAssertEqual(RecordingDetail.subtitle(failed, home: home, timeZone: seoul), "10월 10일 15:32  52분 10초  받아쓰기 실패")
        var silent = ready(textPath: nil)
        silent.transcript = ""
        XCTAssertEqual(RecordingDetail.subtitle(silent, home: home, timeZone: seoul), "10월 10일 15:32  52분 10초  받아쓴 내용 없음")
        XCTAssertEqual(RecordingDetail.when(silent, timeZone: seoul), "2026년 10월 10일 15:32 · 52분 10초")
    }

    func testAudioNoteCountsTheDaysLeftAndExplainsKeptOrDeletedFiles() {
        let now = start + 10 * 86_400
        XCTAssertEqual(RecordingDetail.audioNote(ready(textPath: nil, readyAt: now - 2 * 86_400), audioExists: true, now: now), "5일 뒤 지워져요")
        var deleted = ready(textPath: nil, readyAt: now - 8 * 86_400)
        deleted.audioDeletedAt = now - 86_400
        XCTAssertEqual(RecordingDetail.audioNote(deleted, audioExists: false, now: now), "녹음 파일은 7일이 지나 지웠어요")
        var failed = ready(textPath: nil)
        failed.status = .failed
        XCTAssertEqual(RecordingDetail.audioNote(failed, audioExists: true, now: now), "받아쓰기에 실패한 녹음은 지우지 않아요")
        XCTAssertEqual(RecordingDetail.transcriptText(ready(textPath: nil)), "오늘은 연결 리스트를 봅니다.\n\n노드는 값을 가집니다.")
    }

    func testMissingTextFileIsReportedAndNotOpened() throws {
        let gone = folder.appendingPathComponent("옮겨진.md").path
        let recording = ready(textPath: gone)
        XCTAssertEqual(RecordingDetail.notice(recording, textExists: false), "받아쓴 글 파일을 찾을 수 없어요. 옮기거나 지웠어도 아래 글은 앱에 남아 있어요.")
        XCTAssertNil(RecordingDetail.notice(recording, textExists: true))

        let db = try WGDatabase.inMemory()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        var stored = recording
        stored.id = nil
        let saved = try RecordingStore(db).insert(stored)
        XCTAssertNil(state.recordingTextURL(key: "recording:\(saved.id!)"), "없는 파일은 열지 않는다")
        try Data("# 강의".utf8).write(to: URL(fileURLWithPath: gone))
        XCTAssertEqual(state.recordingTextURL(key: "recording:\(saved.id!)")?.path, gone)
        XCTAssertNil(state.recordingTextURL(key: "file:///Users/me/a.md"))
    }

    func testDetailShowsTheTitleSummaryPlaybackAndFinderButton() throws {
        let audio = folder.appendingPathComponent("7.m4a")
        try Data("a".utf8).write(to: audio)
        let md = folder.appendingPathComponent("강의.md")
        try Data("# 강의".utf8).write(to: md)
        let recording = ready(textPath: md.path, audioPath: audio.path, readyAt: Date().timeIntervalSince1970 - 2 * 86_400)
        let state = AppState(preview: { $0.phase = .ready })
        let text = render(RecordingDetailView(recording: recording).environmentObject(state), size: CGSize(width: 640, height: 520))
        for expected in ["자료구조3주차강의", "연결리스트를설명한강의", "듣기", "Finder에서보기"] {
            XCTAssertTrue(text.contains(expected), "\(expected) 가 보여야 한다: \(text.prefix(400))")
        }
        XCTAssertFalse(text.contains("다시받아쓰기"), "받아쓰기에 성공한 녹음에는 다시 받아쓰기가 없다")
    }

    // MARK: [녹음 삭제]

    func testDeletingAReadyRecordingRemovesItsRowAndAudioButKeepsTheTextFile() throws {
        let database = try WGDatabase.inMemory()
        let audio = folder.appendingPathComponent("7.m4a")
        try Data("a".utf8).write(to: audio)
        let text = folder.appendingPathComponent("강의.md")
        try Data("# 강의".utf8).write(to: text)
        var stored = ready(textPath: text.path, audioPath: audio.path)
        stored.id = nil
        let saved = try RecordingStore(database).insert(stored)
        let state = AppState(preview: { $0.phase = .ready }, database: database)
        state.refreshRecordings()
        XCTAssertEqual(state.recordings.map(\.id), [saved.id])

        state.deleteRecording(saved)

        XCTAssertTrue(state.recordings.isEmpty)
        XCTAssertNil(try RecordingStore(database).find(id: saved.id!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path), "받아쓴 글(.md)은 남는다")
    }

    func testDeletingARecordingThatIsStillTranscribingDoesNothing() throws {
        let database = try WGDatabase.inMemory()
        var stored = ready(textPath: nil)
        stored.id = nil
        stored.status = .transcribing
        let saved = try RecordingStore(database).insert(stored)
        let state = AppState(preview: { $0.phase = .ready }, database: database)
        state.refreshRecordings()

        state.deleteRecording(saved)

        XCTAssertNotNil(try RecordingStore(database).find(id: saved.id!))
        XCTAssertEqual(state.recordings.map(\.id), [saved.id])
    }

    func testLibraryShowsRecordingsAmongItsItems() throws {
        let database = try WGDatabase.inMemory()
        var stored = ready(textPath: nil)
        stored.id = nil
        _ = try RecordingStore(database).insert(stored)
        let state = AppState(preview: { s in
            s.phase = .ready
            s.selectedTab = .chat; s.showsChatResultsOnOpen = true
            let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
            s.chat = ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
        }, database: database)
        let text = render(MainWindow().environmentObject(state), size: CGSize(width: 1180, height: 716))
        XCTAssertTrue(text.contains("자료구조3주차강의"), "전체 종류에 녹음이 보여야 한다: \(text.prefix(400))")
        XCTAssertTrue(text.contains("52분10초"), text)
    }
}
