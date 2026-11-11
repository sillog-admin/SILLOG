import XCTest
@testable import WorkGraphApp

/// Settings saved by older versions must keep decoding the same way.
final class SettingsCompatTests: XCTestCase {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testOldSettingsInheritOrganizeConnection() throws {
        let s = try decode(#"{"llmProvider":"openai","llmBaseURL":"http://h:1/v1","llmModel":"m1","llmAPIKey":"k1","codexModel":"c1","retentionDays":3}"#)
        XCTAssertEqual(s.chatProvider, "openai")
        XCTAssertEqual(s.chatEndpoint.url, "http://h:1/v1")
        XCTAssertEqual(s.chatModelName, "m1")
        XCTAssertTrue(s.chatSameAsOrganize)
        XCTAssertEqual(s.judgeProvider, "gpt")
        XCTAssertEqual(s.judgeGPTProvider, "openai")
        XCTAssertEqual(s.judgeBaseURL, "http://h:1/v1")
        XCTAssertEqual(s.retentionDays, 3)
        XCTAssertTrue(s.captureText, "missing fields fall back to defaults")
    }

    func testJevJudgeAndUnknownProvidersSurvive() throws {
        let s = try decode(#"{"llmProvider":"ollama","judgeProvider":"jev","jevAPIKey":"tk"}"#)
        XCTAssertEqual(s.llmProvider, "codex", "unknown providers fall back to ChatGPT login")
        XCTAssertEqual(s.judgeProvider, "jev")
        XCTAssertEqual(s.judgeEndpoint?.key, "tk")
    }

    func testSeparateChatModelIsKept() throws {
        let s = try decode(#"{"llmProvider":"codex","codexModel":"a","chatProvider":"codex","chatCodexModel":"b"}"#)
        XCTAssertFalse(s.chatSameAsOrganize)
        XCTAssertEqual(s.chatModelName, "b")
    }
}
