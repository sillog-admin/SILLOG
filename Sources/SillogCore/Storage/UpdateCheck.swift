import Foundation

/// Newer SILLOG release on GitHub. CI tags each release v<version>-build.<run number> and stamps the same number into CFBundleVersion.
public enum UpdateCheck {
    public struct Update: Equatable, Sendable {
        public let build: Int
        public let url: URL
    }

    public static let latestURL = URL(string: "https://api.github.com/repos/sillog-admin/SILLOG/releases/latest")!

    /// Args: currentBuild is the running app's CFBundleVersion.
    /// Returns: the latest release when its build is newer, with its SILLOG.dmg link or else its release page; nil otherwise.
    /// Raises: none. Network and parse errors mean no update.
    public static func latest(currentBuild: Int, session: URLSession = .shared) async -> Update? {
        var req = URLRequest(url: latestURL, timeoutInterval: 30)
        req.setValue("SILLOG", forHTTPHeaderField: "User-Agent")    // GitHub rejects requests without one
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, currentBuild: currentBuild)
    }

    static func parse(_ data: Data, currentBuild: Int) -> Update? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String, let mark = tag.range(of: "-build."),
              let build = Int(tag[mark.upperBound...]), build > currentBuild else { return nil }
        let assets = root["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { $0["name"] as? String == "SILLOG.dmg" }?["browser_download_url"] as? String
        guard let url = (dmg ?? root["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Update(build: build, url: url)
    }
}
