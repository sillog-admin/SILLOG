import XCTest
@testable import SillogCore

final class VoiceConversationTests: XCTestCase {
    func testAFullTurnListensSendsAfterAPauseSpeaksAndListensAgain() {
        var voice = VoiceConversation()
        XCTAssertEqual(voice.start(), .listen)
        XCTAssertNil(voice.tick(at: 100), "nothing heard yet")
        voice.heard(at: 100)
        XCTAssertNil(voice.tick(at: 101.4), "still within the pause")
        voice.heard(at: 101.4)
        XCTAssertNil(voice.tick(at: 102.8), "new text restarts the pause")
        XCTAssertEqual(voice.tick(at: 102.9), .send)
        XCTAssertEqual(voice.phase, .answering)
        XCTAssertNil(voice.tick(at: 200))
        XCTAssertEqual(voice.answered("답변"), .speak("답변"))
        XCTAssertEqual(voice.phase, .speaking)
        XCTAssertEqual(voice.spoke(), .listen)
        XCTAssertEqual(voice.phase, .listening)
        XCTAssertNil(voice.tick(at: 300), "the last turn's text does not count")
    }

    func testTapSendsWhileListeningAndSkipsTheReading() {
        var voice = VoiceConversation()
        voice.start()
        XCTAssertEqual(voice.tap(), .send)
        XCTAssertNil(voice.tap(), "a tap while answering does nothing")
        _ = voice.answered("답변")
        XCTAssertEqual(voice.tap(), .listen)
        XCTAssertEqual(voice.phase, .listening)
        XCTAssertNil(voice.spoke(), "the stopped reading does not restart listening twice")
    }

    func testAStoppedOrFailedRunEndsTheMode() {
        var voice = VoiceConversation()
        voice.start(); _ = voice.tap()
        XCTAssertEqual(voice.answered(nil), .end)
        XCTAssertNil(voice.phase)
        voice.start(); _ = voice.tap()
        XCTAssertEqual(voice.answered(""), .end)
    }

    func testEndingIsOnlyReportedOnceAndOffIgnoresEvents() {
        var voice = VoiceConversation()
        XCTAssertNil(voice.end())
        voice.heard(at: 0)
        XCTAssertNil(voice.tick(at: 10))
        XCTAssertNil(voice.tap())
        XCTAssertNil(voice.answered("답변"))
        XCTAssertNil(voice.spoke())
        voice.start()
        XCTAssertEqual(voice.end(), .end)
        XCTAssertNil(voice.end())
    }
}
