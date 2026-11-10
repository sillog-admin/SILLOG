import XCTest
@testable import WorkGraphCore

final class StubURLProtocol: URLProtocol {
    struct Stub { let status: Int; let body: String }
    nonisolated(unsafe) static var queue: [Stub] = []
    nonisolated(unsafe) static var requests: [(url: URL, headers: [String: String], body: [String: Any])] = []
    nonisolated(unsafe) static var rawBodies: [String] = []

    static func reset(_ stubs: [Stub]) { queue = stubs; requests = []; rawBodies = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.requests.append((request.url!, request.allHTTPHeaderFields ?? [:], body))
        Self.rawBodies.append(String(data: data, encoding: .utf8) ?? "")
        let stub = Self.queue.isEmpty ? Stub(status: 500, body: "{}") : Self.queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class OpenAICompatClientTests: XCTestCase {
    private let tool = ToolSpec(name: "record", description: "기록", parameters: .object(["type": "object"]))

    private func makeClient(apiKey: String? = nil) -> OpenAICompatClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "gpt-5.4-mini",
                                  apiKey: apiKey, timeout: 5, session: URLSession(configuration: config))
    }

    private func completion(message: String) -> String {
        #"{"model":"gpt-5.4-mini","choices":[{"index":0,"message":\#(message),"finish_reason":"stop"}],"usage":{"prompt_tokens":11,"completion_tokens":7}}"#
    }

    func testParsesToolCallArgumentsAndSendsExpectedRequest() async throws {
        StubURLProtocol.reset([.init(status: 200, body: completion(message:
            #"{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"record","arguments":"{\"segments\":[]}"}}]}"#))])
        let result = try await makeClient(apiKey: "k").callFunction(system: "sys", user: "usr", tool: tool)
        XCTAssertEqual(String(data: result.arguments, encoding: .utf8), #"{"segments":[]}"#)
        XCTAssertEqual(result.promptTokens, 11)
        XCTAssertEqual(result.completionTokens, 7)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, "http://localhost:5010/v1/chat/completions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer k")
        XCTAssertEqual(request.body["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(request.body["tool_choice"] as? String, "required")
        XCTAssertEqual(request.body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(request.body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        let tools = try XCTUnwrap(request.body["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "record")
    }

    func testFallsBackToJSONInContent() async throws {
        StubURLProtocol.reset([.init(status: 200, body: completion(message: #"{"role":"assistant","content":"{\"segments\":[1]}"}"#))])
        let result = try await makeClient().callFunction(system: "s", user: "u", tool: tool)
        XCTAssertEqual(String(data: result.arguments, encoding: .utf8), #"{"segments":[1]}"#)
    }

    func testFallsBackToCodeFencedJSON() async throws {
        StubURLProtocol.reset([.init(status: 200, body: completion(message:
            #"{"role":"assistant","content":"결과입니다.\n```json\n{\"segments\": [{\"note\": \"중괄호 } 가 문자열 안에\"}]}\n```\n끝"}"#))])
        let result = try await makeClient().callFunction(system: "s", user: "u", tool: tool)
        let parsed = try JSONSerialization.jsonObject(with: result.arguments) as? [String: Any]
        XCTAssertNotNil(parsed?["segments"])
    }

    func testRetriesWithoutToolChoiceWhenServerRejectsIt() async throws {
        StubURLProtocol.reset([
            .init(status: 400, body: #"{"error":{"message":"Unsupported parameter: tool_choice"}}"#),
            .init(status: 200, body: completion(message: #"{"role":"assistant","content":"{\"ok\":true}"}"#)),
        ])
        let result = try await makeClient().callFunction(system: "s", user: "u", tool: tool)
        XCTAssertEqual(String(data: result.arguments, encoding: .utf8), #"{"ok":true}"#)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertNil(StubURLProtocol.requests[1].body["tool_choice"])
    }

    func testAuthFailureIsNotRetried() async {
        StubURLProtocol.reset([.init(status: 500, body: #"{"error":{"message":"Could not parse your authentication token","type":"api_error"}}"#)])
        do {
            _ = try await makeClient().callFunction(system: "s", user: "u", tool: tool)
            XCTFail("에러가 나야 함")
        } catch let error as LLMError {
            guard case .http(let status, let body) = error else { return XCTFail("http 에러여야 함: \(error)") }
            XCTAssertEqual(status, 500)
            XCTAssertTrue(body.contains("authentication token"))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testThrowsWhenNoJSONAnywhere() async {
        StubURLProtocol.reset([.init(status: 200, body: completion(message: #"{"role":"assistant","content":"모르겠습니다"}"#))])
        do {
            _ = try await makeClient().callFunction(system: "s", user: "u", tool: tool)
            XCTFail("에러가 나야 함")
        } catch let error as LLMError {
            guard case .noJSON = error else { return XCTFail("noJSON 이어야 함: \(error)") }
        } catch { XCTFail("\(error)") }
    }

    func testExtractJSONIgnoresBracesInsideStrings() {
        XCTAssertEqual(OpenAICompatClient.extractJSON(from: #"앞 {"a":"}{","b":{"c":1}} 뒤 {"x":2}"#), #"{"a":"}{","b":{"c":1}}"#)
        XCTAssertNil(OpenAICompatClient.extractJSON(from: "JSON 없음"))
    }
}
