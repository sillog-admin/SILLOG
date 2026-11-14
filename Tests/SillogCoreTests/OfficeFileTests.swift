import XCTest
@testable import SillogCore

final class OfficeFileTests: XCTestCase {
    private let samples: [(OfficeFormat, String, [String])] = [
        (.docx, "# 보고서 제목\n한글 & <값> \"인용\" \u{0001}끝\n\n| 이름 | 값 |\n| --- | --- |\n| 사과 | 3 |\n", ["보고서 제목", "사과", "한글 & <값>"]),
        (.pptx, "# 첫 슬라이드\n- 한글 & <값> \"인용\" \u{0001}\n## 둘째 슬라이드\n본문 줄", ["첫 슬라이드", "둘째 슬라이드", "한글 & <값>"]),
        (.xlsx, "항목,설명\n사과,\"한글 & <값>, \"\"인용\"\" \u{0001}\"\n", ["항목", "사과", "한글 & <값>"]),
    ]

    private func write(_ format: OfficeFormat, _ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(format.rawValue)")
        try OfficeFile.data(format, title: "제목", content: content).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func unzip(_ url: URL, _ args: [String]) throws -> (Int32, Data) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = args + [url.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private func part(_ url: URL, _ name: String) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // unzip treats names as wildcards; "[[]" matches a literal "[".
        process.arguments = ["-p", url.path, name.replacingOccurrences(of: "[", with: "[[]")]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testPartsAreValid() throws {
        let required: [OfficeFormat: [String]] = [
            .docx: ["word/document.xml"], .pptx: ["ppt/theme/theme1.xml", "ppt/slides/slide2.xml"], .xlsx: ["xl/worksheets/sheet1.xml"],
        ]
        for (format, content, _) in samples {
            let url = try write(format, content)
            XCTAssertEqual(try unzip(url, ["-tq"]).0, 0, format.rawValue)
            let names = String(decoding: try unzip(url, ["-Z1"]).1, as: UTF8.self).split(separator: "\n").map(String.init)
            for name in ["[Content_Types].xml"] + required[format]! { XCTAssertTrue(names.contains(name), "\(format) \(name)") }
            for name in names where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                XCTAssertTrue(XMLParser(data: Data(try part(url, name).utf8)).parse(), "\(format) \(name)")
            }
        }
    }

    func testRoundTripThroughExtractor() throws {
        for (format, content, expected) in samples {
            let text = try FileTextExtractor.read(try write(format, content)).0
            for value in expected { XCTAssertTrue(text.contains(value), "\(format) missing \(value) in \(text)") }
        }
    }

    func testCSVRows() {
        XCTAssertEqual(OfficeFile.csvRows("\u{FEFF}a,\"b,c\"\r\n\"say \"\"hi\"\"\",\"x\ny\"\n"), [["a", "b,c"], ["say \"hi\"", "x\ny"]])
        XCTAssertEqual(OfficeFile.csvRows("a,\n,b"), [["a", ""], ["", "b"]])
        XCTAssertEqual(OfficeFile.csvRows("a,\"open\nrest"), [["a", "open\nrest"]])
        XCTAssertEqual(OfficeFile.csvRows(""), [])
        XCTAssertEqual(OfficeFile.csvRows("size,price\n55\" TV,1000\n65\" TV,2000"), [["size", "price"], ["55\" TV", "1000"], ["65\" TV", "2000"]])
    }

    func testXLSXCells() throws {
        let url = try write(.xlsx, "12.5,-3,007,\"1,234\",1234567890123456,\"=HYPERLINK(\"\"x\"\")\"")
        let sheet = try part(url, "xl/worksheets/sheet1.xml")
        XCTAssertTrue(sheet.contains(#"<c r="A1"><v>12.5</v></c>"#))
        XCTAssertTrue(sheet.contains(#"<c r="B1"><v>-3</v></c>"#))
        for (ref, text) in [("C1", "007"), ("D1", "1,234"), ("E1", "1234567890123456"), ("F1", "=HYPERLINK(&quot;x&quot;)")] {
            XCTAssertTrue(sheet.contains(#"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(text)</t>"#), ref)
        }
        XCTAssertFalse(sheet.contains("<f>"))
    }

    func testSlides() throws {
        XCTAssertEqual(OfficeFile.slides("# A\n- x\n## B\ny"), ["# A\n- x", "## B\ny"])
        XCTAssertEqual(OfficeFile.slides("intro\n# A"), ["intro", "# A"])
        XCTAssertEqual(OfficeFile.slides("# A\n```\n# c\n```\n## B"), ["# A\n```\n# c\n```", "## B"])
        let url = try write(.pptx, "# A\n- x\n## B\ny")
        XCTAssertEqual(try part(url, "ppt/presentation.xml").components(separatedBy: "<p:sldId ").count - 1, 2)
        XCTAssertEqual(try part(url, "[Content_Types].xml").components(separatedBy: "presentationml.slide+xml").count - 1, 2)
    }

    func testFileExtensionAndData() throws {
        XCTAssertEqual(ChatArtifact(title: "t", format: "pptx", content: "").fileExtension, "pptx")
        XCTAssertEqual(ChatArtifact(title: "t", format: "markdown", content: "").fileExtension, "md")
        XCTAssertEqual(ChatArtifact(title: "t", format: "weird", content: "").fileExtension, "txt")
        XCTAssertEqual(try ChatArtifact(title: "t", format: "csv", content: "a,b").fileData(), Data("a,b".utf8))
        XCTAssertEqual(try ChatArtifact(title: "t", format: "docx", content: "x").fileData().prefix(4), Data("PK\u{3}\u{4}".utf8))
    }

    func testFollowUpsFollowTablesAndStructureAndSkipMadeFormats() {
        let table = "요약\n\n| 이름 | 값 |\n| --- | ---: |\n| 사과 | 3 |"
        XCTAssertEqual(OfficeFormat.followUps(text: table, artifacts: []), [.xlsx])
        XCTAssertEqual(OfficeFormat.followUps(text: "|a|b|\n|-|:-:|\n|1|2|", artifacts: []), [.xlsx])
        let long = "# 개요\n" + String(repeating: "설명 문장입니다. ", count: 40) + "\n## 다음 단계\n- 하나\n- 둘"
        XCTAssertEqual(OfficeFormat.followUps(text: long, artifacts: []), [.docx, .pptx])
        XCTAssertEqual(OfficeFormat.followUps(text: table + "\n" + long, artifacts: [ChatArtifact(title: "t", format: "docx", content: "x")]), [.xlsx, .pptx])
        XCTAssertEqual(OfficeFormat.followUps(text: "짧은 답\n# 하나\n# 둘", artifacts: []), [])
        let fenced = "```\n| --- | --- |\n# 주석\n# 주석\n```\n" + String(repeating: "본문 ", count: 100)
        XCTAssertEqual(OfficeFormat.followUps(text: fenced, artifacts: []), [])
    }
}
