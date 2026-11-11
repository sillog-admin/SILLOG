import Foundation

/// 같은 자료를 하나의 노드로 모으기 위한 키 정규화.
/// 브라우저에서 본 논문과 내려받은 PDF가 같은 키가 되도록 하는 것이 목적이다.
public enum URINormalizer {
    static let trackingParams: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "yclid", "mc_cid", "mc_eid", "igshid",
        "ref", "ref_src", "ref_url", "si", "spm", "_hsenc", "_hsmi", "vero_id",
    ]
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    public static func normalize(url raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("file://") {
            return normalize(filePath: trimmed, home: NSHomeDirectory())
        }
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = comps.host?.lowercased(), !host.isEmpty else {
            return trimmed
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = comps.percentEncodedPath
        let items = comps.percentEncodedQueryItems ?? []

        // 로컬 개발 서버: 쿼리는 화면 상태일 뿐이라 버린다.
        if localHosts.contains(host) || host.hasSuffix(".localhost") {
            let port = comps.port ?? (scheme == "https" ? 443 : 80)
            return "local:\(port)\(path.isEmpty ? "/" : path)"
        }
        if host == "arxiv.org" || host.hasSuffix(".arxiv.org"), let id = arxivID(in: path) {
            return "arxiv:\(id)"
        }
        if host == "doi.org" || host == "dx.doi.org" {
            let doi = String(path.dropFirst())
            if !doi.isEmpty { return "doi:\(doi.removingPercentEncoding ?? doi)" }
        }
        if host == "youtu.be" {
            let id = path.split(separator: "/").first.map(String.init) ?? ""
            if !id.isEmpty { return "https://youtube.com/watch?v=\(id)" }
        }
        if ["youtube.com", "m.youtube.com", "music.youtube.com"].contains(host), path == "/watch",
           let v = items.first(where: { $0.name == "v" })?.value {
            return "https://youtube.com/watch?v=\(v)"
        }

        var kept: [URLQueryItem]
        if host.hasPrefix("google."), path == "/search" {
            kept = items.filter { $0.name == "q" }
        } else if host == "search.naver.com" {
            kept = items.filter { $0.name == "query" }
        } else {
            kept = items.filter { !isTracking($0.name) }
        }
        kept.sort { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }

        // 해시 라우팅(#/path)만 남기고 나머지 프래그먼트는 버린다.
        var fragment: String?
        if let f = comps.percentEncodedFragment, f.hasPrefix("/") || f.hasPrefix("!/") { fragment = f }
        if fragment == nil {
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if path == "/" { path = "" }
        }

        var out = "\(scheme)://\(host)"
        if let port = comps.port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            out += ":\(port)"
        }
        out += path
        if !kept.isEmpty {
            out += "?" + kept.map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }.joined(separator: "&")
        }
        if let fragment { out += "#\(fragment)" }
        return out
    }

    public static func normalize(filePath raw: String, home: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.lowercased().hasPrefix("file://") {
            if let url = URL(string: path), !url.path.isEmpty {
                path = url.path
            } else {
                let stripped = String(path.dropFirst("file://".count))
                path = stripped.removingPercentEncoding ?? stripped
            }
        }
        let homeStd = (home as NSString).standardizingPath
        if path == "~" { return "file:~" }
        if path.hasPrefix("~/") { path = homeStd + String(path.dropFirst(1)) }
        path = (path as NSString).standardizingPath
        if path == homeStd { return "file:~" }
        if path.hasPrefix(homeStd + "/") { return "file:~" + String(path.dropFirst(homeStd.count)) }
        return "file:" + path
    }

    /// 정규화된 자료 키를 다시 열 수 있는 주소로 되돌린다 (그래프 카드에서 자료 누르기). 파일·웹 주소가 아니면 nil.
    public static func openableURL(forKey key: String, home: String) -> URL? {
        if key.hasPrefix("file:") {
            let path = String(key.dropFirst("file:".count))
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path.hasPrefix("~") ? home + path.dropFirst(1) : path)
        }
        if key.hasPrefix("http://") || key.hasPrefix("https://") { return URL(string: key) }
        if key.hasPrefix("arxiv:") { return URL(string: "https://arxiv.org/abs/" + key.dropFirst("arxiv:".count)) }
        if key.hasPrefix("doi:") {
            let doi = String(key.dropFirst("doi:".count))
            return doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: "https://doi.org/" + $0) }
        }
        if key.hasPrefix("local:") {                                     // local:포트/경로 (443 이면 https)
            let rest = key.dropFirst("local:".count)
            guard let slash = rest.firstIndex(of: "/"), let port = Int(rest[..<slash]) else { return nil }
            let path = rest[slash...]
            return URL(string: port == 443 ? "https://localhost\(path)" : port == 80 ? "http://localhost\(path)" : "http://localhost:\(port)\(path)")
        }
        return nil
    }

    /// "2401.05566", "2401.05566v2", "2401.05566v2.pdf" 에서 arXiv ID를 뽑는다.
    public static func arxivID(inFileName name: String) -> String? {
        firstGroup(#"^([0-9]{4}\.[0-9]{4,5})(v[0-9]+)?(\.pdf)?$"#, in: name)
    }

    static func arxivID(in path: String) -> String? {
        firstGroup(#"^/(?:abs|pdf)/([0-9]{4}\.[0-9]{4,5})(?:v[0-9]+)?(?:\.pdf)?/?$"#, in: path)
    }

    static func isTracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_") || trackingParams.contains(lower)
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
