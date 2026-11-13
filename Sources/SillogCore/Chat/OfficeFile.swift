import Foundation

public enum OfficeFormat: String, CaseIterable, Sendable { case docx, pptx, xlsx }

extension ChatArtifact {
    public var fileExtension: String {
        OfficeFormat(rawValue: format)?.rawValue
            ?? ["markdown": "md", "text": "txt", "txt": "txt", "json": "json", "html": "html", "csv": "csv", "svg": "svg"][format] ?? "txt"
    }

    /// Args: none.
    /// Returns: the bytes to save; an Office package for docx/pptx/xlsx, else the UTF-8 content.
    /// Raises: ChatToolError.unavailable when the Office package cannot be zipped.
    public func fileData() throws -> Data {
        try OfficeFormat(rawValue: format).map { try OfficeFile.data($0, title: title, content: content) } ?? Data(content.utf8)
    }
}

/// Builds minimal Office Open XML packages from the text the model writes.
public enum OfficeFile {
    /// Args: format picks the package; title names untitled slides; content is Markdown (docx, pptx) or CSV (xlsx).
    /// Returns: the zipped package.
    /// Raises: ChatToolError.unavailable when zip fails.
    public static func data(_ format: OfficeFormat, title: String, content: String) throws -> Data {
        switch format {
        case .docx: return try zip(docx(content))
        case .pptx: return try zip(pptx(title: title, content))
        case .xlsx: return try zip(xlsx(content))
        }
    }

    /// Args: markdown is the deck source.
    /// Returns: one chunk per `# `/`## ` heading, heading line included; leading text before any heading is its own chunk.
    /// Raises: none.
    public static func slides(_ markdown: String) -> [String] {
        var chunks: [[String]] = []
        var fence = false
        for line in lines(markdown) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fence.toggle() }
            if chunks.isEmpty || (!fence && (line.hasPrefix("# ") || line.hasPrefix("## "))) { chunks.append([line]) } else { chunks[chunks.count - 1].append(line) }
        }
        return chunks.map { $0.joined(separator: "\n") }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Args: text is RFC 4180 CSV.
    /// Returns: rows of fields; parsing is lenient and an unclosed quote runs to the end.
    /// Raises: none.
    public static func csvRows(_ text: String) -> [[String]] {
        var chars = Array(text)[...]
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        while let c = chars.popFirst() {
            if quoted {
                if c != "\"" { field.append(c) } else if chars.first == "\"" { field.append(c); chars.removeFirst() } else { quoted = false }
            } else if c == "\"" && field.isEmpty { quoted = true
            } else if c == "," { row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" { rows.append(row + [field]); row = []; field = ""
            } else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { rows.append(row + [field]) }
        return rows
    }

    /// Escapes text for XML 1.0 and drops the control characters Word refuses.
    static func xml(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars where (u.value >= 0x20 || u == "\t" || u == "\n" || u == "\r") && u.value != 0xFFFE && u.value != 0xFFFF {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    // MARK: - DOCX

    static func docx(_ md: String) -> [String: String] {
        let source = lines(md)
        var body = "", code = false, i = 0
        while i < source.count {
            let line = source[i], t = line.trimmingCharacters(in: .whitespaces)
            i += 1
            if t.hasPrefix("```") { code.toggle(); continue }
            if code { body += para(run(line, props: #"<w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="19"/>"#)); continue }
            if t.hasPrefix("|") {
                var block = [t]
                while i < source.count, case let next = source[i].trimmingCharacters(in: .whitespaces), next.hasPrefix("|") { block.append(next); i += 1 }
                if let rows = ChatMarkdownTable.rows(in: block.joined(separator: "\n")) { body += table(rows) } else { body += block.map { para(runs($0)) }.joined() }
                continue
            }
            if t.isEmpty || t == "---" { continue }
            let hashes = t.prefix(while: { $0 == "#" }).count
            if hashes > 0, t.dropFirst(hashes).hasPrefix(" ") {
                body += para(runs(String(t.dropFirst(hashes + 1)), bold: true, size: hashes <= 3 ? [36, 30, 26][hashes - 1] : 24))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                body += para(runs("• " + t.dropFirst(2)), pPr: #"<w:ind w:left="360" w:hanging="360"/>"#)
            } else if t.hasPrefix("> ") {
                body += para(runs(String(t.dropFirst(2)), italic: true), pPr: #"<w:ind w:left="720"/>"#)
            } else {
                body += para(runs(t))
            }
        }
        let document = head + #"<w:document xmlns:w="\#(w)"><w:body>\#(body.isEmpty ? "<w:p/>" : body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>"#
        return [
            "[Content_Types].xml": contentTypes([
                ("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
                ("/word/styles.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"),
            ]),
            "_rels/.rels": rels([("officeDocument", "word/document.xml")]),
            "word/_rels/document.xml.rels": rels([("styles", "styles.xml")]),
            "word/document.xml": document,
            // No eastAsia font so each app falls back to its own Korean font without a missing-font warning.
            "word/styles.xml": head + #"<w:styles xmlns:w="\#(w)"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="ko-KR"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120"/></w:pPr></w:pPrDefault></w:docDefaults></w:styles>"#,
        ]
    }

    private static func para(_ runs: String, pPr: String = "") -> String {
        "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + runs + "</w:p>"
    }

    private static func run(_ text: String, props: String) -> String {
        "<w:r>" + (props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>") + #"<w:t xml:space="preserve">\#(xml(text))</w:t></w:r>"#
    }

    // shortcut: no hyperlinks or inline code font, add when users ask
    private static func runs(_ text: String, bold: Bool = false, italic: Bool = false, size: Int? = nil) -> String {
        plain(text).components(separatedBy: "**").enumerated().filter { !$0.element.isEmpty }.map { index, part -> String in
            let props = (bold || index % 2 == 1 ? "<w:b/>" : "") + (italic ? "<w:i/>" : "") + (size.map { #"<w:sz w:val="\#($0)"/>"# } ?? "")
            return run(part, props: props)
        }.joined()
    }

    private static func table(_ rows: [[String]]) -> String {
        let n = rows[0].count, width = 9026 / n
        let borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map { #"<w:\#($0) w:val="single" w:sz="4" w:space="0" w:color="auto"/>"# }.joined()
        let grid = String(repeating: #"<w:gridCol w:w="\#(width)"/>"#, count: n)
        let body = rows.enumerated().map { r, row -> String in
            "<w:tr>" + row.map { #"<w:tc><w:tcPr><w:tcW w:w="\#(width)" w:type="dxa"/></w:tcPr>"# + para(runs($0, bold: r == 0)) + "</w:tc>" }.joined() + "</w:tr>"
        }.joined()
        return #"<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>\#(borders)</w:tblBorders></w:tblPr><w:tblGrid>\#(grid)</w:tblGrid>\#(body)</w:tbl><w:p/>"#
    }

    // MARK: - PPTX

    static func pptx(title: String, _ md: String) -> [String: String] {
        let chunks = slides(md).isEmpty ? [""] : slides(md)
        var parts: [String: String] = [
            "_rels/.rels": rels([("officeDocument", "ppt/presentation.xml")]),
            "ppt/_rels/presentation.xml.rels": rels([("slideMaster", "slideMasters/slideMaster1.xml"), ("theme", "theme/theme1.xml")]
                + chunks.indices.map { ("slide", "slides/slide\($0 + 1).xml") }),
            "ppt/presentation.xml": head + #"<p:presentation \#(pns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\#(chunks.indices.map { #"<p:sldId id="\#(256 + $0)" r:id="rId\#(3 + $0)"/>"# }.joined())</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#,
            "ppt/slideMasters/slideMaster1.xml": head + #"<p:sldMaster \#(pns)><p:cSld>\#(emptyTree)</p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>"#,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": rels([("slideLayout", "../slideLayouts/slideLayout1.xml"), ("theme", "../theme/theme1.xml")]),
            "ppt/slideLayouts/slideLayout1.xml": head + #"<p:sldLayout \#(pns) type="blank" preserve="1"><p:cSld name="Blank">\#(emptyTree)</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": rels([("slideMaster", "../slideMasters/slideMaster1.xml")]),
            "ppt/theme/theme1.xml": theme,
        ]
        var overrides = [
            ("/ppt/presentation.xml", "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"),
            ("/ppt/slideMasters/slideMaster1.xml", "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"),
            ("/ppt/slideLayouts/slideLayout1.xml", "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"),
            ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
        ]
        for (index, chunk) in chunks.enumerated() {
            var body = lines(chunk), heading = title
            if let first = body.first, first.hasPrefix("# ") || first.hasPrefix("## ") {
                heading = String(first.drop(while: { $0 == "#" }).dropFirst()); body.removeFirst()
            }
            let paragraphs = body.compactMap(slideParagraph).joined()
            let slide = head + #"<p:sld \#(pns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#
                + textBox(id: 2, y: 457200, cy: 1143000, bodyPr: #"<a:bodyPr wrap="square"/>"#, paragraphs: #"<a:p><a:r><a:rPr lang="\#(lang)" sz="3200" b="1"/><a:t>\#(xml(plain(heading).replacingOccurrences(of: "**", with: "")))</a:t></a:r></a:p>"#)
                + textBox(id: 3, y: 1714500, cy: 4572000, bodyPr: #"<a:bodyPr wrap="square"><a:normAutofit/></a:bodyPr>"#, paragraphs: paragraphs.isEmpty ? "<a:p/>" : paragraphs)
                + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            parts["ppt/slides/slide\(index + 1).xml"] = slide
            parts["ppt/slides/_rels/slide\(index + 1).xml.rels"] = rels([("slideLayout", "../slideLayouts/slideLayout1.xml")])
            overrides.append(("/ppt/slides/slide\(index + 1).xml", "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"))
        }
        parts["[Content_Types].xml"] = contentTypes(overrides)
        return parts
    }

    private static func slideParagraph(_ line: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "---" || t.hasPrefix("```") || t.allSatisfy({ "|-: ".contains($0) }) { return nil }
        // shortcut: table rows become " · "-joined lines, draw a:tbl when decks need real tables
        if t.hasPrefix("|") { t = t.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ") }
        let bullet = t.hasPrefix("- ") || t.hasPrefix("* ")
        if bullet { t = String(t.dropFirst(2)) } else if t.hasPrefix("#") { t = String(t.drop(while: { $0 == "#" || $0 == " " })) }
        let pPr = bullet ? #"<a:pPr marL="342900" indent="-342900"><a:buChar char="•"/></a:pPr>"# : "<a:pPr><a:buNone/></a:pPr>"
        return #"<a:p>\#(pPr)<a:r><a:rPr lang="\#(lang)" sz="2000"/><a:t>\#(xml(plain(t).replacingOccurrences(of: "**", with: "")))</a:t></a:r></a:p>"#
    }

    /// PowerPoint proofs each text run in this language.
    private static var lang: String { L10n.current == .ko ? "ko-KR" : "en-US" }

    private static func textBox(id: Int, y: Int, cy: Int, bodyPr: String, paragraphs: String) -> String {
        #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Text \#(id)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="609600" y="\#(y)"/><a:ext cx="10972800" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody>\#(bodyPr)<a:lstStyle/>\#(paragraphs)</p:txBody></p:sp>"#
    }

    private static let pns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
    private static let emptyTree = #"<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree>"#
    private static let theme: String = {
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "44546A"), ("lt2", "E7E6E6"), ("accent1", "4472C4"), ("accent2", "ED7D31"),
                      ("accent3", "A5A5A5"), ("accent4", "FFC000"), ("accent5", "5B9BD5"), ("accent6", "70AD47"), ("hlink", "0563C1"), ("folHlink", "954F72")]
            .map { #"<a:\#($0.0)><a:srgbClr val="\#($0.1)"/></a:\#($0.0)>"# }.joined()
        let font = #"<a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/>"#
        let fill = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#
        return head + #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office"><a:themeElements><a:clrScheme name="Office">\#(colors)</a:clrScheme><a:fontScheme name="Office"><a:majorFont>\#(font)</a:majorFont><a:minorFont>\#(font)</a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst>\#(String(repeating: fill, count: 3))</a:fillStyleLst><a:lnStyleLst>\#(String(repeating: #"<a:ln w="6350">\#(fill)</a:ln>"#, count: 3))</a:lnStyleLst><a:effectStyleLst>\#(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst><a:bgFillStyleLst>\#(String(repeating: fill, count: 3))</a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"#
    }()

    // MARK: - XLSX

    // shortcut: no styles.xml or sharedStrings, so no bold header or column widths; add when users ask
    static func xlsx(_ csv: String) -> [String: String] {
        let number = #"^-?(0|[1-9][0-9]{0,14})(\.[0-9]+)?$"#
        let rows = csvRows(csv).enumerated().map { r, row -> String in
            // Never write <f>: record text could carry =WEBSERVICE or =HYPERLINK.
            let cells = row.enumerated().filter { !$0.element.isEmpty }.map { c, value -> String in
                let ref = column(c) + "\(r + 1)"
                return value.range(of: number, options: .regularExpression) != nil ? #"<c r="\#(ref)"><v>\#(value)</v></c>"#
                    : #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(xml(String(value.prefix(32767))))</t></is></c>"#
            }.joined()
            return #"<row r="\#(r + 1)">\#(cells)</row>"#
        }.joined()
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        return [
            "[Content_Types].xml": contentTypes([
                ("/xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
                ("/xl/worksheets/sheet1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"),
            ]),
            "_rels/.rels": rels([("officeDocument", "xl/workbook.xml")]),
            "xl/_rels/workbook.xml.rels": rels([("worksheet", "worksheets/sheet1.xml")]),
            "xl/workbook.xml": head + #"<workbook xmlns="\#(main)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/worksheets/sheet1.xml": head + #"<worksheet xmlns="\#(main)"><sheetData>\#(rows)</sheetData></worksheet>"#,
        ]
    }

    private static func column(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { n -= 1; name = String(Character(UnicodeScalar(UInt8(65 + n % 26)))) + name; n /= 26 }
        return name
    }

    // MARK: - Package

    private static let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    private static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]*)\]\(([^)\s]*)\)"#, with: "$1 ($2)", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
    }

    private static func contentTypes(_ overrides: [(String, String)]) -> String {
        head + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>"#
            + overrides.map { #"<Override PartName="\#($0.0)" ContentType="\#($0.1)"/>"# }.joined() + "</Types>"
    }

    private static func rels(_ items: [(String, String)]) -> String {
        head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + items.enumerated().map { #"<Relationship Id="rId\#($0.offset + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/\#($0.element.0)" Target="\#($0.element.1)"/>"# }.joined()
            + "</Relationships>"
    }

    /// Args: parts maps package paths to XML text.
    /// Returns: the zip archive bytes.
    /// Raises: ChatToolError.unavailable when writing the parts or running /usr/bin/zip fails.
    private static func zip(_ parts: [String: String]) throws -> Data {
        let fm = FileManager.default, tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = tmp.appendingPathComponent("p")
        defer { try? fm.removeItem(at: tmp) }
        do {
            for (path, text) in parts {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = root
            // `-r .` sidesteps zip's wildcard handling of the [Content_Types].xml name.
            process.arguments = ["-qrXD", "../o.zip", "."]
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            try process.run()
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "zip exit \(process.terminationStatus): \(detail)"]) }
            return try Data(contentsOf: tmp.appendingPathComponent("o.zip"))
        } catch {
            AppLog.write("office zip failed: \(error.localizedDescription)")
            throw ChatToolError.unavailable(tr("Office 파일을 만들지 못했습니다."))
        }
    }
}
