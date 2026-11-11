import XCTest
@testable import SillogCore

final class JevClientTests: XCTestCase {
    private func client() -> JevClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return JevClient(endpoint: JevEndpoint(url: JevEndpoint.typesafeURL, model: "jev-latest", key: "tk-test"), session: URLSession(configuration: config))
    }

    func testSendsSystemOneRequestAndReadsChoice() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"model":"jev-1.13.0","answers":{"activity":{"type":"choice","choice":"t_a","confidence":0.82,"probabilities":{"t_a":0.9,"new":0.1}}}}"#)])
        let question = JevQuestion(instructions: "Which goal?", options: ["t_a": "Card UI", "new": "Other goal"])

        let answers = try await client().choose(state: "row text", questions: ["activity": question])

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tk-test")
        XCTAssertEqual(request.body["model"] as? String, "jev-latest")
        XCTAssertEqual(request.body["state"] as? String, "row text")
        let sent = try XCTUnwrap((request.body["questions"] as? [String: Any])?["activity"] as? [String: Any])
        XCTAssertEqual(sent["type"] as? String, "choice")
        XCTAssertEqual(sent["criteria"] as? [String: String], ["t_a": "Card UI", "new": "Other goal"])
        XCTAssertEqual(answers["activity"], JevChoice(choice: "t_a", confidence: 0.82, probabilities: ["t_a": 0.9, "new": 0.1]))
    }

    func testHTTPErrorKeepsStatusAndBody() async {
        StubURLProtocol.reset([.init(status: 401, body: #"{"error":"invalid api key"}"#)])
        do {
            _ = try await client().choose(state: "x", questions: ["q": JevQuestion(instructions: "?", options: ["a": "a", "b": "b"])])
            XCTFail("expected an error")
        } catch let JevError.http(code, body) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(body.contains("invalid api key"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
