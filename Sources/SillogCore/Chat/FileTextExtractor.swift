import AppKit
import Foundation
import PDFKit
import Vision

/// 원본은 형식에 관계없이 보관하고, 읽을 수 있는 내용만 검색용 텍스트로 추출한다.
enum FileTextExtractor {
    static func read(_ url: URL) throws -> (String, String) {
        let ext = url.pathExtension.lowercased()
        var text = ""
        if ext == "pdf", let pdf = PDFDocument(url: url) {
            text = (0..<pdf.pageCount).map { "[\($0 + 1)쪽]\n\(pdf.page(at: $0)?.string ?? "")" }.joined(separator: "\n")
            if text.filter({ $0.isLetter }).isEmpty {
                return ("", "이미지로 된 PDF입니다. 원본은 보관되지만 본문 검색에는 텍스트가 있는 PDF가 필요합니다.")
            }
        } else if ["docx", "pptx", "xlsx"].contains(ext) {
            text = try office(url, ext: ext)
        } else if ["png", "jpg", "jpeg", "tiff", "heic", "webp", "gif"].contains(ext) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.automaticallyDetectsLanguage = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["ko-KR", "en-US"].filter { supported.contains($0) }
            try VNImageRequestHandler(url: url).perform([request])
            text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
        } else if ["rtf", "doc"].contains(ext) {
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        } else if let value = try? String(contentsOf: url, encoding: .utf8) {
            text = value
        }
        let clipped = String(text.prefix(2_000_000))
        let note = text.isEmpty ? "원본을 보관했습니다. 이 파일에서 검색 가능한 텍스트를 추출하지 못했습니다."
            : text.count > clipped.count ? "검색용 텍스트는 처음 200만 자까지 보관합니다." : ""
        return (clipped, note)
    }

    private static func office(_ url: URL, ext: String) throws -> String {
        let names = try unzip(url, arguments: ["-Z1"]).components(separatedBy: "\n")
        let selected: [String]
        switch ext {
        case "docx": selected = names.filter { $0 == "word/document.xml" || $0 == "word/footnotes.xml" || $0 == "word/endnotes.xml" }
        case "pptx": selected = names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
        default: selected = names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
        }
        let shared = ext == "xlsx" && names.contains("xl/sharedStrings.xml")
            ? XMLText.parse(try unzip(url, arguments: ["-p", "xl/sharedStrings.xml"]), shared: [])?.strings ?? [] : []
        var pages: [String] = [], count = 0
        for name in selected.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard count < 2_000_000 else { break }
            guard let parsed = XMLText.parse(try unzip(url, arguments: ["-p", name]), shared: shared) else { continue }
            let page = "[\(name)]\n\(parsed.text)"; pages.append(page); count += page.count
        }
        return pages.joined(separator: "\n\n")
    }

    private static func unzip(_ url: URL, arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = Array(arguments.prefix(1)) + [url.path] + Array(arguments.dropFirst())
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard data.count + chunk.count <= 8_000_000 else { process.terminate(); process.waitUntilExit(); throw ChatToolError.unavailable("문서의 압축 해제 내용이 너무 큽니다.") }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ChatToolError.unavailable("문서 내용을 추출하지 못했습니다.") }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class XMLText: NSObject, XMLParserDelegate {
    var text = ""
    var strings: [String] = []
    let shared: [String]
    var capturing = false, value = "", sharedCell = false, inString = false, stringValue = ""
    init(shared: [String]) { self.shared = shared }
    static func parse(_ xml: String, shared: [String]) -> XMLText? {
        let result = XMLText(shared: shared), parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false; parser.delegate = result
        return parser.parse() ? result : nil
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "c" { sharedCell = attributes["t"] == "s" }
        if name == "si" { inString = true; stringValue = "" }
        if name == "t" || name == "v" { capturing = true; value = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capturing { value += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "t" || name == "v" {
            let part = name == "v" && sharedCell ? Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? value : value
            if inString { stringValue += part } else { text += part }
            capturing = false
        }
        if name == "si" { strings.append(stringValue); inString = false }
        if name == "c" || name == "tab" { text += "\t" }
        if name == "p" || name == "row" || name == "br" { text += "\n" }
    }
}
