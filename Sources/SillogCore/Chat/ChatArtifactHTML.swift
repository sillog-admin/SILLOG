import Foundation

public enum ChatArtifactHTML {
    /// Args: artifact는 Markdown, HTML, CSV, JSON, TXT 또는 Office 원문(docx·pptx Markdown, xlsx CSV) 결과물이다.
    /// Returns: 외부 리소스·스크립트를 차단한 미리보기/내보내기용 HTML.
    /// Raises: 없음. Markdown은 제목·목록·표·코드 블록·기본 강조를 지원한다.
    public static func render(_ artifact: ChatArtifact) -> String {
        let body: String
        if artifact.format == "html" {
            body = artifact.content
                .replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script\\s*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?is)<(?:meta|base|link)\\b[^>]*>", with: "", options: .regularExpression)
        } else if artifact.format == "markdown" || artifact.format == "docx" { body = markdown(artifact.content) }
        else if artifact.format == "pptx" { body = OfficeFile.slides(artifact.content).map { "<section>\(markdown($0))</section>" }.joined() }
        else if artifact.format == "xlsx" || artifact.format == "csv" {
            body = "<table>" + OfficeFile.csvRows(artifact.content).map { "<tr>" + $0.map { "<td>\(escape($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
        } else if artifact.format == "json", (try? JSONSerialization.jsonObject(with: Data(artifact.content.utf8), options: .fragmentsAllowed)) != nil {
            body = "<pre>\(escape(reindent(artifact.content)))</pre>"
        } else { body = "<pre>\(escape(artifact.content))</pre>" }
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>\(escape(artifact.title))</title>
        <style>body{font:14px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;color:#141210;background:#fff;margin:32px 28px;overflow-wrap:anywhere}h1,h2,h3{line-height:1.3}h1{font-size:24px}h2{font-size:18px;margin-top:28px}p{white-space:pre-wrap}pre{white-space:pre-wrap;background:#F6F5F4;padding:16px;border-radius:6px}code{font-family:ui-monospace,monospace}table{border-collapse:collapse;width:100%;margin:20px 0}td,th{border:1px solid #E5E2DF;padding:8px 12px;text-align:left}tr:first-child td{background:#F6F5F4;font-weight:600}blockquote{border-left:3px solid #E5E2DF;margin-left:0;padding-left:16px;color:#736D68}a{color:#265ed4}hr{border:0;border-top:1px solid #E5E2DF;margin:24px 0}section{border-bottom:1px solid #E5E2DF;padding-bottom:24px}@media print{body{margin:0}pre,table{break-inside:avoid}section{break-after:page}}</style>
        </head><body>\(body)</body></html>
        """
    }

    /// Args: text는 이스케이프할 원문이다.
    /// Returns: HTML 본문·속성에서 안전한 텍스트.
    /// Raises: 없음.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Re-indents valid JSON without re-serializing, so key order, number text and duplicate keys stay as written.
    private static func reindent(_ json: String) -> String {
        var out = "", depth = 0, inString = false, escaped = false
        let pad = { String(repeating: "  ", count: depth) }
        for c in json {
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true; out.append(c)
            case "{", "[": depth += 1; out += "\(c)\n\(pad())"
            case "}", "]":
                depth -= 1
                if out.hasSuffix("{\n\(pad())  ") || out.hasSuffix("[\n\(pad())  ") { out.removeLast(pad().count + 3); out.append(c) }
                else { out += "\n\(pad())\(c)" }
            case ",": out += ",\n\(pad())"
            case ":": out += ": "
            case " ", "\n", "\r", "\r\n", "\t": break
            default: out.append(c)
            }
        }
        return out
    }

    /// Args: text는 문단 안의 Markdown이다.
    /// Returns: 기본 강조·코드·HTTPS 링크를 적용한 HTML. 코드 안의 *는 그대로 둔다.
    /// Raises: 없음.
    private static func inline(_ text: String) -> String {
        let escaped = escape(text)
        var result = "", rest = escaped[...]
        while let code = rest.range(of: "`[^`]+`", options: .regularExpression) {
            result += emphasis(String(rest[..<code.lowerBound])) + "<code>\(rest[code].dropFirst().dropLast())</code>"
            rest = rest[code.upperBound...]
        }
        return result + emphasis(String(rest))
    }

    private static func emphasis(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?!\*)"#, with: "<em>$1</em>", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
    }

    /// Args: text는 Markdown 문서이다.
    /// Returns: 문서 블록을 HTML로 변환한 본문.
    /// Raises: 없음.
    private static func markdown(_ text: String) -> String {
        var result = "", code = false, list = false, ol = false, table = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if list { result += "</ul>"; list = false }
                if ol { result += "</ol>"; ol = false }
                if table { result += "</table>"; table = false }
                result += code ? "</code></pre>" : "<pre><code>"; code.toggle(); continue
            }
            if code { result += escape(line) + "\n"; continue }
            let rule = line.filter { $0 != " " }
            // Checked first so "* * *" is a rule, not a bullet.
            let isRule = rule.count >= 3 && Set(rule).count == 1 && "-*_".contains(rule.first!)
            let isList = !isRule && (line.hasPrefix("- ") || line.hasPrefix("* "))
            let olMarker = line.range(of: #"^\d+\. "#, options: .regularExpression)
            let isTable = line.hasPrefix("|") && line.hasSuffix("|")
            if list && !isList { result += "</ul>"; list = false }
            if ol && olMarker == nil { result += "</ol>"; ol = false }
            if table && !isTable { result += "</table>"; table = false }
            if isRule { result += "<hr>" }
            else if isList {
                if !list { result += "<ul>"; list = true }
                result += "<li>\(inline(String(line.dropFirst(2))))</li>"
            } else if let olMarker {
                // Keep the written number, so a list split by a blank or indented line keeps counting.
                if !ol { let n = line[olMarker].dropLast(2); result += n == "1" ? "<ol>" : "<ol start=\"\(n)\">"; ol = true }
                result += "<li>\(inline(String(line[olMarker.upperBound...])))</li>"
            } else if isTable {
                if !table { result += "<table>"; table = true }
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                result += "<tr>" + line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map { "<td>\(inline(String($0)))</td>" }.joined() + "</tr>"
            } else {
                let level = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") {
                    result += "<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>"
                } else if line.hasPrefix("> ") { result += "<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>" }
                else if !line.isEmpty { result += "<p>\(inline(line))</p>" }
            }
        }
        if code { result += "</code></pre>" }
        if list { result += "</ul>" }
        if ol { result += "</ol>" }
        if table { result += "</table>" }
        return result
    }
}
