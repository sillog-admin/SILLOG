import XCTest
@testable import SillogApp

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

    func testAnOldAPIJudgeWithItsOwnServerBecomesCustom() throws {
        let own = try decode(#"{"llmProvider":"openai","llmBaseURL":"http://a/v1","judgeGPTProvider":"openai","judgeBaseURL":"http://b/v1"}"#)
        XCTAssertEqual(own.judgeChoice, .customAPI)
        let same = try decode(#"{"llmProvider":"openai","llmBaseURL":"http://a/v1","judgeGPTProvider":"openai","judgeBaseURL":"http://a/v1"}"#)
        XCTAssertEqual(same.judgeChoice, .api)
    }

    func testJudgeChoiceRoundTrips() throws {
        var s = AppSettings()
        for choice in AppSettings.JudgeChoice.allCases {
            s.judgeChoice = choice
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
            XCTAssertEqual(decoded.judgeChoice, choice)
        }
        XCTAssertEqual(try decode(#"{"judgeProvider":"decisions","decisionsAPIKey":"sk"}"#).decisionsAPIKey, "sk")
    }

    func testLegacyDefaultsKeysMoveOnce() throws {
        let suite = "sillog-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{}".utf8), forKey: "workgraph.settings.v1")
        defaults.set(true, forKey: "workgraph.onboardingCompleted")
        defaults.set(false, forKey: "sillog.launchedBefore")
        defaults.set(true, forKey: "workgraph.launchedBefore")

        UserDefaults.migrateLegacyKeys(defaults)

        XCTAssertEqual(defaults.data(forKey: "sillog.settings.v1"), Data("{}".utf8))
        XCTAssertTrue(defaults.bool(forKey: "sillog.onboardingCompleted"))
        XCTAssertNil(defaults.object(forKey: "workgraph.onboardingCompleted"))
        XCTAssertFalse(defaults.bool(forKey: "sillog.launchedBefore"), "an existing new key wins")
    }

    func testSeparateChatModelIsKept() throws {
        let s = try decode(#"{"llmProvider":"codex","codexModel":"a","chatProvider":"codex","chatCodexModel":"b"}"#)
        XCTAssertFalse(s.chatSameAsOrganize)
        XCTAssertEqual(s.chatModelName, "b")
    }
}
