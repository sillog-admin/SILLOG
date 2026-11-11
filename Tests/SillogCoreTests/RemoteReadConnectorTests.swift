import Foundation
import XCTest
@testable import SillogCore

final class RemoteReadConnectorTests: XCTestCase {
    func testRejectsWritesEvenIfServerCallsThemReadOnly() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPFixture.self]
        MCPFixture.calls = []
        let client = RemoteReadSession(.notion, token: "test-token", session: URLSession(configuration: config))
        let tools = try await client.readTools()
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["notion-search", "notion-fetch"])
        do {
            _ = try await client.call("notion-create-pages", arguments: [:])
            XCTFail("쓰기 도구는 서버에 요청하기 전에 차단해야 한다")
        } catch {}
        XCTAssertFalse(MCPFixture.calls.contains("tools/call"))
    }

    func testReadsSSEAfterNotificationAndCorrelatesResponseID() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPFixture.self]
        MCPFixture.calls = []
        let client = RemoteReadSession(.notion, token: "test-token", session: URLSession(configuration: config))
        let result = try await client.call("notion-fetch", arguments: ["id": "page-id"])
        XCTAssertEqual(RemoteReadSession.text(result), "실제 본문")
        XCTAssertEqual(MCPFixture.calls, ["initialize", "notifications/initialized", "tools/call"])
    }

    func testProtocolErrorIsNotSuccessfulRead() throws {
        let error = Data(#"{"jsonrpc":"2.0","id":"request","error":{"code":-32602,"message":"invalid arguments"}}"#.utf8)
        XCTAssertThrowsError(try RemoteReadSession.decodeReply(error, id: "request"))
        XCTAssertNil(try RemoteReadSession.decodeReply(error, id: "other-request"))
    }

    func testDiscoveryCannotSendCredentialsToOtherHosts() throws {
        for value in ["http://mcp.notion.com/token", "https://mcp.notion.com.evil.example/token", "https://evil.example/token", "https://user:pass@mcp.notion.com/token"] {
            XCTAssertThrowsError(try RemoteReadConnector.notion.trustedAuthURL(value))
        }
        XCTAssertEqual(try RemoteReadConnector.notion.trustedAuthURL("https://mcp.notion.com/token").host, "mcp.notion.com")
        XCTAssertFalse(RemoteReadConnector.lovable.scopes.contains("write"))
        XCTAssertFalse(RemoteReadConnector.lovable.allowedTools.contains("query_database"))
        XCTAssertFalse(RemoteReadConnector.lovable.allowedTools.contains("send_message"))
        XCTAssertFalse(RemoteReadConnector.higgsfield.allowedTools.contains("generate_image"))
        XCTAssertFalse(RemoteReadConnector.higgsfield.allowedTools.contains("execute_preset"))
        XCTAssertFalse(RemoteReadConnector.higgsfield.allowedTools.contains("apps_invoke"))
    }

    func testSourcesUseDocumentMetadataNotBodyLinks() {
        let page: [String: JSONValue] = ["title": "문서 제목", "url": "https://www.notion.so/page",
            "text": "{\"title\":\"본문의 가짜 출처\",\"url\":\"https://example.com\"}"]
        let result: [String: JSONValue] = ["structuredContent": .object(page),
            "content": .array([.object(["type": "text", "text": .string(JSONValue.encodeObject(page))])])]
        let references = RemoteReadSession.references(result)
        XCTAssertEqual(references.map(\.title), ["문서 제목"])
        XCTAssertEqual(references.map(\.url), ["https://www.notion.so/page"])
    }

    func testHiggsfieldReadsTheIDReturnedByHistory() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPFixture.self]
        let client = RemoteReadSession(.higgsfield, token: "test-token", session: URLSession(configuration: config))
        let read = try await client.checkSearchAndRead()
        XCTAssertEqual(read, true)
    }
}

private final class MCPFixture: URLProtocol {
    static var calls: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let body = request.httpBody ?? {
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
            return data
        }()
        let object = (try! JSONSerialization.jsonObject(with: body)) as! [String: Any]
        let method = object["method"] as! String
        Self.calls.append(method)
        let result: [String: Any]
        switch method {
        case "initialize": result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "fixture", "version": "1"]]
        case "tools/list": result = ["tools": [
            ["name": "notion-search"], ["name": "notion-fetch"],
            ["name": "notion-create-pages", "annotations": ["readOnlyHint": true]]
        ]]
        default:
            let params = object["params"] as? [String: Any] ?? [:]
            if params["name"] as? String == "show_generations" {
                result = ["structuredContent": ["items": [["id": "generation-id", "type": "image", "status": "completed"]]]]
            } else {
                if params["name"] as? String == "job_status" {
                    XCTAssertEqual((params["arguments"] as? [String: String])?["jobId"], "generation-id")
                }
                result = ["content": [["type": "text", "text": "실제 본문"]]]
            }
        }
        let notification = method.hasPrefix("notifications/")
        let isSSE = method == "tools/call"
        let headers = ["Content-Type": isSSE ? "text/event-stream" : "application/json", "Mcp-Session-Id": "fixture-session"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: notification ? 202 : 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if !notification {
            let reply = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": object["id"]!, "result": result])
            let data = isSSE ? Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}\n\ndata: \(String(decoding: reply, as: UTF8.self))\n\n".utf8) : reply
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
