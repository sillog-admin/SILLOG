import XCTest
@testable import SillogCore

final class DrivePickerTests: XCTestCase {
    func testPageUsesProjectNumberAndEscapesValues() {
        let page = DrivePicker.page(token: "tok</script>", apiKey: "key", clientID: "123456-abc.apps.googleusercontent.com", state: "s1")
        XCTAssertTrue(page.contains(#"setAppId("123456")"#))
        XCTAssertTrue(page.contains(#""tok<\/script>""#), "token cannot close the script tag")
        XCTAssertFalse(page.contains("tok</script>"))
        XCTAssertTrue(page.contains(#""/drive-picked?state=s1&ids=""#))
    }

    func testFilesReadsMetadataAndSkipsBadIDs() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.reset([.init(status: 200, body: #"{"id":"a1","name":"Plan","mimeType":"application/pdf","webViewLink":"https://x/a1"}"#)])
        let files = try await DrivePicker.files(ids: ["a1", "../bad"], token: "tok", session: URLSession(configuration: config))
        XCTAssertEqual(files, [ChatDriveFile(id: "a1", name: "Plan", mimeType: "application/pdf", url: "https://x/a1")])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(StubURLProtocol.requests.first?.headers["Authorization"], "Bearer tok")
    }

    func testAddDriveFilesDedupesAndTurnsDriveOn() {
        var scope = ChatScope()
        let file = ChatDriveFile(id: "a1", name: "Plan", mimeType: "", url: "")
        scope.addDriveFiles([file, file])
        XCTAssertEqual(scope.driveFiles, [file])
        XCTAssertEqual(scope.connectors, ["drive"])
        scope.addDriveFiles([file])
        XCTAssertEqual(scope.connectors, ["drive"])
    }

    func testDriveSearchOnlyListsThisChatsFiles() async throws {
        var scope = ChatScope()
        scope.addDriveFiles([ChatDriveFile(id: "a1", name: "Budget plan", mimeType: "application/pdf", url: "https://x/a1"),
                             ChatDriveFile(id: "b2", name: "Notes", mimeType: "text/plain", url: "https://x/b2")])
        let tools = ChatTools(db: try SillogDatabase.inMemory(), scope: scope, connectorToken: { _ in XCTFail("no network"); return "" })
        let output = try await tools.driveSearch("budget")
        XCTAssertEqual(output.sources.map(\.id), ["drive:a1"])
    }
}
