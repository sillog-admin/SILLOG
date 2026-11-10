import XCTest
@testable import WorkGraphApp

@MainActor
final class SlackOAuthTests: XCTestCase {
    func testMatchingCallbackReturnsDecodedCode() throws {
        let url = URL(string: "sillog://oauth/slack?state=session&code=code%2Bvalue")!
        XCTAssertEqual(try SlackOAuth.authorizationCode(from: url, state: "session"), "code+value")
    }

    func testForeignCallbackDoesNotEndPendingSession() throws {
        for value in [
            "https://oauth/slack?state=session&code=value",
            "sillog://other/slack?state=session&code=value",
            "sillog://oauth/other?state=session&code=value",
            "sillog://oauth:8765/slack?state=session&code=value",
            "sillog://user@oauth/slack?state=session&code=value",
            "sillog://oauth/slack?state=session&code=value#fragment",
            "sillog://oauth/slack?state=other&code=value",
            "sillog://oauth/slack?code=value",
            "sillog://oauth/slack?state=session&state=other&code=value"
        ] {
            XCTAssertNil(try SlackOAuth.authorizationCode(from: URL(string: value)!, state: "session"), value)
        }
    }

    func testDeniedOrMalformedMatchingCallbackFails() {
        for query in ["error=access_denied", "code=", "code=one&code=two", "unused=value"] {
            let url = URL(string: "sillog://oauth/slack?state=session&\(query)")!
            XCTAssertThrowsError(try SlackOAuth.authorizationCode(from: url, state: "session"), query)
        }
    }

    func testCallbackWithoutPendingSessionIsIgnored() {
        XCTAssertFalse(SlackOAuth.handle(URL(string: "sillog://oauth/slack?state=session&code=value")!))
    }
}
