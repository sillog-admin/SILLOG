import Foundation

public enum ChatArtifactHTML {
    /// Args: artifact는 Markdown, HTML, CSV, JSON 또는 TXT 결과물이다.
    /// Returns: 외부 리소스·스크립트를 차단한 미리보기/내보내기용 HTML.
    /// Raises: 없음. Markdown은 제목·목록·표·코드 블록·기본 강조를 지원한다.
    public static func render(_ artifact: ChatArtifact) -> String {
        let body: String
        if artifact.format == "html" {
            body = artifact.content
                .replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script\\s*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?is)<(?:meta|base|link)\\b[^>]*>", with: "", options: .regularExpression)
        } else if artifact.format == "markdown" { body = markdown(artifact.content) }
        else { body = "<pre>\(escape(artifact.content))</pre>" }
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>\(escape(artifact.title))</title>
        <style>body{font:15px/1.75 -apple-system,BlinkMacSystemFont,sans-serif;color:#25262a;background:#fff;margin:36px;overflow-wrap:anywhere}h1,h2,h3{line-height:1.3}h1{font-size:30px}h2{margin-top:32px}p{white-space:pre-wrap}pre{white-space:pre-wrap;background:#f4f5f7;padding:16px;border-radius:8px}code{font-family:ui-monospace,monospace}table{border-collapse:collapse;width:100%;margin:20px 0}td,th{border:1px solid #ddd;padding:8px;text-align:left}blockquote{border-left:3px solid #aaa;margin-left:0;padding-left:16px;color:#555}a{color:#265ed4}@media print{body{margin:0}pre,table{break-inside:avoid}section{break-after:page}}</style>
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

    /// Args: text는 문단 안의 Markdown이다.
    /// Returns: 기본 강조·코드·HTTPS 링크를 적용한 HTML.
    /// Raises: 없음.
    private static func inline(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
            .replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
    }

    /// Args: text는 Markdown 문서이다.
    /// Returns: 문서 블록을 HTML로 변환한 본문.
    /// Raises: 없음.
    private static func markdown(_ text: String) -> String {
        var result = "", code = false, list = false, table = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if list { result += "</ul>"; list = false }
                if table { result += "</table>"; table = false }
                result += code ? "</code></pre>" : "<pre><code>"; code.toggle(); continue
            }
            if code { result += escape(line) + "\n"; continue }
            let isList = line.hasPrefix("- ") || line.hasPrefix("* ")
            let isTable = line.hasPrefix("|") && line.hasSuffix("|")
            if list && !isList { result += "</ul>"; list = false }
            if table && !isTable { result += "</table>"; table = false }
            if isList {
                if !list { result += "<ul>"; list = true }
                result += "<li>\(inline(String(line.dropFirst(2))))</li>"
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
        if table { result += "</table>" }
        return result
    }
}
