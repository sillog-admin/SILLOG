import XCTest
@testable import SillogCore

final class DecisionsClientTests: XCTestCase {
    private func client() -> DecisionsClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return DecisionsClient(key: "sk-test", session: URLSession(configuration: config))
    }

    func testSendsDecisionsRequestAndReadsChoice() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"model":"gpt-6-luna","answers":[{"type":"choice","name":"activity","choice":"t_a","confidence":0.8,"probabilities":[{"value":"t_a","probability":0.85},{"value":"new","probability":0.15}]}],"usage":{}}"#)])
        let question = ChoiceQuestion(instructions: "Which goal?", options: ["t_a": "Card UI", "new": "Other goal"])

        let answers = try await client().choose(state: "row text", questions: ["activity": question])

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/decisions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")
        XCTAssertEqual(request.body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(request.body["input"] as? String, "row text")
        let sent = try XCTUnwrap((request.body["questions"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["type"] as? String, "choice")
        XCTAssertEqual(sent["name"] as? String, "activity")
        XCTAssertEqual(sent["choices"] as? [[String: String]], [["value": "new", "description": "Other goal"], ["value": "t_a", "description": "Card UI"]])
        XCTAssertEqual(answers["activity"], ChoiceAnswer(choice: "t_a", confidence: 0.8, probabilities: ["t_a": 0.85, "new": 0.15]))
    }

    func testRefusalIsLeftOut() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"answers":[{"type":"refusal","name":"activity"}]}"#)])
        let answers = try await client().choose(state: "x", questions: ["activity": ChoiceQuestion(instructions: "?", options: ["a": "a", "b": "b"])])
        XCTAssertTrue(answers.isEmpty)
    }

    func testHTTPErrorKeepsStatusAndBody() async {
        StubURLProtocol.reset([.init(status: 401, body: #"{"error":{"message":"Incorrect API key"}}"#)])
        do {
            try await client().verify()
            XCTFail("expected an error")
        } catch let ChoiceError.http(code, body) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(body.contains("Incorrect API key"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
