import XCTest
@testable import WorkGraphCore

final class URINormalizerTests: XCTestCase {
    func testStripsTrackingFragmentAndTrailingSlash() {
        XCTAssertEqual(URINormalizer.normalize(url: "https://Example.com/path/?utm_source=x&fbclid=1#frag"),
                       "https://example.com/path")
        XCTAssertEqual(URINormalizer.normalize(url: "https://www.example.com/"), "https://example.com")
    }

    func testSortsRemainingQueryParams() {
        XCTAssertEqual(URINormalizer.normalize(url: "https://example.com/list?b=2&a=1&utm_medium=mail"),
                       "https://example.com/list?a=1&b=2")
    }

    func testYouTubeKeepsOnlyVideoId() {
        XCTAssertEqual(URINormalizer.normalize(url: "https://www.youtube.com/watch?v=abc123&t=10s&si=zzz"),
                       "https://youtube.com/watch?v=abc123")
        XCTAssertEqual(URINormalizer.normalize(url: "https://youtu.be/abc123?t=5"),
                       "https://youtube.com/watch?v=abc123")
    }

    func testArxivAbsAndPdfShareOneKey() {
        XCTAssertEqual(URINormalizer.normalize(url: "https://arxiv.org/abs/2401.05566v2"), "arxiv:2401.05566")
        XCTAssertEqual(URINormalizer.normalize(url: "https://arxiv.org/pdf/2401.05566"), "arxiv:2401.05566")
        XCTAssertEqual(URINormalizer.normalize(url: "https://arxiv.org/pdf/2401.05566v1.pdf"), "arxiv:2401.05566")
    }

    func testDoi() {
        XCTAssertEqual(URINormalizer.normalize(url: "https://doi.org/10.1145/12345.678"), "doi:10.1145/12345.678")
    }

    func testLocalhostDropsQuery() {
        XCTAssertEqual(URINormalizer.normalize(url: "http://localhost:3000/dashboard?tab=1"), "local:3000/dashboard")
        XCTAssertEqual(URINormalizer.normalize(url: "http://127.0.0.1:8080/"), "local:8080/")
    }

    func testSearchKeepsOnlyQuery() {
        XCTAssertEqual(URINormalizer.normalize(url: "https://www.google.com/search?q=react+key+prop&oq=re&sourceid=chrome"),
                       "https://google.com/search?q=react+key+prop")
    }

    func testHashRoutingIsKept() {
        XCTAssertEqual(URINormalizer.normalize(url: "https://app.example.com/#/board/1"),
                       "https://app.example.com/#/board/1")
    }

    func testFilePaths() {
        XCTAssertEqual(URINormalizer.normalize(filePath: "/Users/me/proj/a.swift", home: "/Users/me"), "file:~/proj/a.swift")
        XCTAssertEqual(URINormalizer.normalize(filePath: "file:///Users/me/My%20Docs/a.pdf", home: "/Users/me"), "file:~/My Docs/a.pdf")
        XCTAssertEqual(URINormalizer.normalize(filePath: "~/proj/../proj/a.swift", home: "/Users/me"), "file:~/proj/a.swift")
        XCTAssertEqual(URINormalizer.normalize(filePath: "/opt/tool/x.sh", home: "/Users/me"), "file:/opt/tool/x.sh")
    }

    func testNonHttpIsReturnedTrimmed() {
        XCTAssertEqual(URINormalizer.normalize(url: "  chrome://settings  "), "chrome://settings")
    }

    // 그래프 카드에서 자료를 누르면 정규화된 키를 다시 열 수 있는 주소로 되돌린다
    func testOpenableURLTurnsKeysBackIntoAddresses() {
        let home = "/Users/me"
        XCTAssertEqual(URINormalizer.openableURL(forKey: "file:~/My Docs/a.pdf", home: home), URL(fileURLWithPath: "/Users/me/My Docs/a.pdf"))
        XCTAssertEqual(URINormalizer.openableURL(forKey: "file:/opt/tool/x.sh", home: home), URL(fileURLWithPath: "/opt/tool/x.sh"))
        XCTAssertEqual(URINormalizer.openableURL(forKey: "https://example.com/list?a=1", home: home)?.absoluteString, "https://example.com/list?a=1")
        XCTAssertEqual(URINormalizer.openableURL(forKey: "arxiv:2401.05566", home: home)?.absoluteString, "https://arxiv.org/abs/2401.05566")
        XCTAssertEqual(URINormalizer.openableURL(forKey: "doi:10.1145/12345.678", home: home)?.absoluteString, "https://doi.org/10.1145/12345.678")
        XCTAssertEqual(URINormalizer.openableURL(forKey: "local:5173/board", home: home)?.absoluteString, "http://localhost:5173/board")
        XCTAssertEqual(URINormalizer.openableURL(forKey: "local:443/", home: home)?.absoluteString, "https://localhost/")
    }

    func testOpenableURLRefusesKeysThatAreNotAddresses() {
        for key in ["chrome://settings", "notion:abc", "javascript:alert(1)", "file:", ""] {
            XCTAssertNil(URINormalizer.openableURL(forKey: key, home: "/Users/me"), key)
        }
    }
}
