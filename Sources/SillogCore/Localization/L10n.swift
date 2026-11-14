import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case ko, en

    /// Language name used in LLM prompts for generated titles and summaries.
    public var promptName: String { self == .ko ? "Korean" : "English" }

    /// `promptName` for tool schema descriptions written in Korean.
    public var nameInKorean: String { self == .ko ? "한국어" : "영어" }

    /// Args: text is a user-facing name such as a task title.
    /// Returns: true when its script fits this language: Korean needs Hangul, English has none.
    /// Raises: none.
    public func fitsScript(_ text: String) -> Bool {
        let hasHangul = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
        return hasHangul == (self == .ko)
    }

    /// Korean for a Korean system, English otherwise.
    public static var system: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("ko") == true ? .ko : .en
    }
}

/// UI text keyed by the Korean source. Interpolated values become `%@` in the key, in order.
public struct LocalizedText: ExpressibleByStringInterpolation, Sendable {
    public var key: String
    public var args: [String]

    public init(stringLiteral value: String) { key = value; args = [] }

    public init(stringInterpolation: Interpolation) { key = stringInterpolation.key; args = stringInterpolation.args }

    public struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) { key += "%@"; args.append("\(value)") }
    }
}

public enum L10n {
    nonisolated(unsafe) public static var current: AppLanguage = .ko

    public static let english: [String: String] = {
        guard let url = BundledResources.core?.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()

    /// Returns: the text in the current language; the Korean source when no translation exists.
    public static func tr(_ text: LocalizedText) -> String {
        let format = current == .en ? english[text.key] ?? text.key : text.key
        return fill(format, text.args)
    }

    /// Runtime keys such as stored enum raw values.
    public static func tr(key: String) -> String { tr(LocalizedText(stringLiteral: key)) }

    /// Returns: the Korean source with its values filled in, for logs, hashes and model input that must not follow the app language.
    public static func korean(_ text: LocalizedText) -> String { fill(text.key, text.args) }

    /// Fills `%@` in order, or `%1$@`-style when a translation reorders the values.
    static func fill(_ format: String, _ args: [String]) -> String {
        guard !args.isEmpty else { return format }
        var out = "", next = 0
        var rest = Substring(format)
        while let range = rest.range(of: #"%(\d+\$)?@"#, options: .regularExpression) {
            out += rest[..<range.lowerBound]
            let token = rest[range].dropFirst().dropLast()
            let index = token.isEmpty ? next : (Int(token.dropLast()) ?? 1) - 1
            if token.isEmpty { next += 1 }
            out += args.indices.contains(index) ? args[index] : ""
            rest = rest[range.upperBound...]
        }
        return out + rest
    }
}

/// Shorthand for `L10n.tr`.
public func tr(_ text: LocalizedText) -> String { L10n.tr(text) }
