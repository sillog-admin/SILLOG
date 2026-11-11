import Foundation

// Identifier formats and check-digit rules come from the public specifications of each country.
// They were cross-checked against stdnum-js (MIT, Copyright © 2020, David Koblas) and
// validator.js (MIT, Copyright (c) 2018 Chris O'Hara). See THIRD_PARTY_NOTICES.md.

/// Replaces personal data and secrets with tags like `[PHONE]` before text leaves the device.
public enum PIIMasker {
    enum Kind: String, Sendable {
        case secret = "SECRET", id = "ID", email = "EMAIL", card = "CARD", phone = "PHONE", account = "ACCOUNT", address = "ADDRESS"
    }

    struct Rule {
        let name: String
        let kind: Kind
        let regex: NSRegularExpression
        let group: Int
        // A label that must appear shortly before the match. For bare digit runs whose check digit alone is too weak.
        let label: NSRegularExpression?
        // Receives the match without spaces, dots, hyphens and brackets.
        let isValid: (String) -> Bool

        init(_ name: String, _ kind: Kind, _ pattern: String, group: Int = 0, label: String? = nil, isValid: @escaping (String) -> Bool = { _ in true }) {
            self.name = name; self.kind = kind; self.regex = try! NSRegularExpression(pattern: pattern); self.group = group
            self.label = label.map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }; self.isValid = isValid
        }
    }

    // ASCII-only word edges. `\b` fails next to Hangul, kana and Han, which count as word characters.
    private static let edge = (start: "(?<![A-Za-z0-9])", end: "(?![A-Za-z0-9])")
    // Edges for digit groups, so a group is not cut out of a longer run like a card number or a hex dump.
    private static let run = (start: #"(?<![\d-])(?<!\d )"#, end: #"(?![\d-])(?! \d)"#)

    // Earlier rules claim their characters first, so a phone number is never read as an account number.
    // Only formats with a distinct shape, a strong check digit or a label are listed, so plain numbers stay readable.
    // shortcut: no names, unit-level addresses or unlabelled bare IDs, add a local NER model for those.
    static let rules: [Rule] = [
        Rule("private-key", .secret, #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
        Rule("api-key", .secret, edge.start + #"(?:sk-[A-Za-z0-9_-]{20,}|sk_(?:live|test)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"#),
        Rule("bearer", .secret, #"(?i)\bbearer\s+([A-Za-z0-9._~+/=-]{20,})"#, group: 1),
        // A value after a key name. It must hold a digit so prose like "token: unlimited" stays.
        Rule("key-value", .secret, #"(?i)(?:api[_-]?key|secret|token|password|passwd|비밀번호)["']?\s*[:=]\s*["']?((?=[A-Za-z0-9_\-./+=]*\d)[A-Za-z0-9_\-./+=]{8,})"#, group: 1),
        Rule("email", .email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        Rule("iban", .account, edge.start + #"[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?"# + edge.end, isValid: isIBAN),
        Rule("card", .card, run.start + #"(?:(?:\d{4}[- ]){3}\d{4}|\d{16}|3[47]\d{2}[- ]?\d{6}[- ]?\d{5})"# + run.end, isValid: passesLuhn),
        Rule("intl-phone", .phone, #"(?<![A-Za-z0-9+])\+\d{1,3}[- .]?(?:\(\d{1,4}\)[- .]?)?\d(?:[- .]?\d){6,12}(?!\d)"#),
        Rule("kr-phone", .phone, #"(?<![\d-])01[016789][- .]?\d{3,4}[- .]?\d{4}(?!\d)|(?<![\d-])0\d{1,2}-\d{3,4}-\d{4}(?![\d-])"#),

        Rule("kr-rrn", .id, #"(?<!\d)\d{6}-[1-8]\d{6}(?!\d)"#),
        // Area 000 and 666, group 00 and serial 0000 are never issued. Covers ITIN.
        Rule("us-ssn", .id, #"(?<![\d-])(?!000|666)\d{3}-(?!00)\d{2}-(?!0000)\d{4}(?![\d-])"#),
        Rule("cn-ric", .id, edge.start + #"\d{6}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]"# + edge.end, isValid: isChineseID),
        Rule("jp-mynumber", .id, run.start + #"\d{4}[- ]\d{4}[- ]\d{4}"# + run.end, isValid: isMyNumber),
        Rule("in-aadhaar", .id, run.start + #"[2-9]\d{3}[- ]\d{4}[- ]\d{4}"# + run.end, isValid: passesVerhoeff),
        Rule("in-pan", .id, edge.start + #"[A-Z]{5}\d{4}[A-Z]"# + edge.end),
        Rule("hk-hkid", .id, edge.start + #"[A-NP-Z]{1,2}\d{6}(?:\([0-9A]\)|[0-9A])"# + edge.end, isValid: isHKID),
        Rule("tw-id", .id, edge.start + #"[A-Z][1289]\d{8}"# + edge.end, isValid: isTaiwanID),
        // The check rule is not published. This is the commonly documented one.
        Rule("sg-nric", .id, edge.start + #"[STFG]\d{7}[A-Z]"# + edge.end, isValid: isNRIC),
        Rule("ca-sin", .id, run.start + #"\d{3}[- ]\d{3}[- ]\d{3}"# + run.end, isValid: passesLuhn),
        Rule("mx-curp", .id, edge.start + #"[A-Z]{4}\d{6}[HMX][A-Z]{5}[0-9A-Z]\d"# + edge.end, isValid: isCURP),
        Rule("br-cpf", .id, #"(?<![\d.-])(?:\d{3}\.\d{3}\.\d{3}-\d{2}|\d{11})(?![\d-])(?!\.\d)"#, isValid: isCPF),
        Rule("gb-nino", .id, edge.start + #"(?!BG|GB|NK|KN|TN|NT|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?\d{2} ?\d{2} ?\d{2} ?[A-D]"# + edge.end),
        Rule("fr-nir", .id, edge.start + #"[12] ?\d{2} ?\d{2} ?(?:\d{2}|2[AB]) ?\d{3} ?\d{3} ?\d{2}"# + edge.end, isValid: isNIR),
        Rule("it-cf", .id, edge.start + #"[A-Z]{6}\d{2}[A-EHLMPRST]\d{2}[A-Z]\d{3}[A-Z]"# + edge.end),
        Rule("es-dni", .id, edge.start + #"(?:\d{8}|[XYZ]\d{7})[A-HJ-NP-TV-Z]"# + edge.end, isValid: isSpanishID),
        Rule("de-idnr", .id, #"(?<![\d-])[1-9]\d{10}(?![\d-])"#, isValid: isGermanTaxID),
        Rule("pl-pesel", .id, #"(?<![\d-])\d{11}(?![\d-])"#, isValid: isPESEL),
        Rule("se-pnr", .id, #"(?<![\d-])(?:\d{2})?\d{6}[-+]\d{4}(?![\d-])"#, isValid: isPersonnummer),
        Rule("au-tfn", .id, run.start + #"\d{3} \d{3} \d{3}"# + run.end, isValid: isTFN),
        // About one random number in ten passes these checks, so the bare forms need their label.
        Rule("jp-mynumber", .id, #"(?<![\d-])\d{12}(?![\d-])"#, label: "マイナンバー|個人番号|my ?number", isValid: isMyNumber),
        Rule("in-aadhaar", .id, #"(?<![\d-])[2-9]\d{11}(?![\d-])"#, label: "aadhaar|aadhar|आधार|uidai", isValid: passesVerhoeff),
        Rule("nl-bsn", .id, #"(?<![\d-])\d{9}(?![\d-])"#, label: "bsn|burgerservicenummer|sofi", isValid: isBSN),
        Rule("au-tfn", .id, #"(?<![\d-])\d{9}(?![\d-])"#, label: "tfn|tax file", isValid: isTFN),

        Rule("nanp-phone", .phone, run.start + #"(?:\(\d{3}\) ?|\d{3}[- .])\d{3}[- .]\d{4}"# + #"(?![\d-])"#),
        // Ten digits would also take ISBN-10 and business registration numbers. Letters at the edges rule out UUIDs.
        Rule("kr-account", .account, #"(?<![0-9A-Za-z-])\d{2,6}-\d{2,6}-\d{2,8}(?:-\d{1,3})?(?![0-9A-Za-z-])"#, isValid: { (11...14).contains($0.count) }),
    ]

    // Set from the app setting. Off sends text as recorded.
    nonisolated(unsafe) public static var enabled = true

    // shortcut: which address formats are found depends on the Mac's region, replace with a local model for even coverage.
    private static let addresses = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)

    /// Args: text is any text bound for an external model.
    /// Returns: the text with each match replaced by its tag, for example `[PHONE]`. Unchanged when `enabled` is false.
    public static func mask(_ text: String) -> String {
        guard enabled else { return text }
        let result = NSMutableString(string: text)
        for item in matches(in: text).sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: item.range, with: "[\(item.kind.rawValue)]")
        }
        return result as String
    }

    /// Args: text is the text to scan.
    /// Returns: non-overlapping matches with the rule that found each one.
    static func matches(in text: String) -> [(range: NSRange, kind: Kind, rule: String)] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        var found: [(range: NSRange, kind: Kind, rule: String)] = []
        func claim(_ range: NSRange, _ kind: Kind, _ rule: String) {
            guard range.length > 0, !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            found.append((range, kind, rule))
        }
        for rule in rules {
            for match in rule.regex.matches(in: text, range: whole) {
                let range = match.range(at: rule.group)
                if let label = rule.label {
                    let before = NSRange(location: max(0, range.location - 40), length: min(40, range.location))
                    guard label.firstMatch(in: text, range: before) != nil else { continue }
                }
                let compact = source.substring(with: range).filter { !" .-()".contains($0) }
                if rule.isValid(compact) { claim(range, rule.kind, rule.name) }
            }
        }
        for match in addresses?.matches(in: text, range: whole) ?? [] { claim(match.range, .address, "address") }
        return found
    }

    // MARK: Check digits

    private static func digits(_ text: some StringProtocol) -> [Int]? {
        let values = text.compactMap(\.wholeNumberValue)
        return values.count == text.count ? values : nil
    }

    private static func weighted(_ values: some Sequence<Int>, _ weights: [Int]) -> Int {
        zip(values, weights).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func isDate(month: Int, day: Int) -> Bool { (1...12).contains(month) && (1...31).contains(day) }

    private static func passesLuhn(_ text: String) -> Bool {
        guard let values = digits(text) else { return false }
        let sum = values.reversed().enumerated().reduce(0) { sum, item in
            let doubled = item.offset % 2 == 1 ? item.element * 2 : item.element
            return sum + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    private static let verhoeffD = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5], [2, 3, 4, 0, 1, 7, 8, 9, 5, 6], [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
                                    [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1], [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
                                    [8, 7, 6, 5, 9, 3, 2, 1, 0, 4], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]]
    private static let verhoeffP = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4], [5, 8, 0, 3, 7, 9, 6, 1, 4, 2], [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
                                    [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1], [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8]]

    private static func passesVerhoeff(_ text: String) -> Bool {
        guard let values = digits(text) else { return false }
        return values.reversed().enumerated().reduce(0) { verhoeffD[$0][verhoeffP[$1.offset % 8][$1.element]] } == 0
    }

    private static func isChineseID(_ text: String) -> Bool {
        guard let values = digits(text.prefix(17)), let check = text.last else { return false }
        let expected = Array("10X98765432")[weighted(values, [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]) % 11]
        return String(check).uppercased() == String(expected)
    }

    private static func isMyNumber(_ text: String) -> Bool {
        guard let values = digits(text), values.count == 12 else { return false }
        let remainder = weighted(values, [6, 5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) % 11
        return values[11] == (remainder <= 1 ? 0 : 11 - remainder)
    }

    private static func isHKID(_ text: String) -> Bool {
        // A single-letter prefix counts as a leading space worth 36.
        let values = (text.count == 8 ? [36] : []) + text.dropLast().compactMap { $0.isNumber ? $0.wholeNumberValue : $0.asciiValue.map { Int($0) - 55 } }
        guard values.count == 8, let check = text.last else { return false }
        let expected = (11 - weighted(values, [9, 8, 7, 6, 5, 4, 3, 2]) % 11) % 11
        return check == (expected == 10 ? "A" : Character(String(expected)))
    }

    private static func isTaiwanID(_ text: String) -> Bool {
        guard let letter = text.first, let index = Array("ABCDEFGHJKLMNPQRSTUVXYWZIO").firstIndex(of: letter), let values = digits(text.dropFirst()) else { return false }
        return ((index + 10) / 10 + (index + 10) % 10 * 9 + weighted(values, [8, 7, 6, 5, 4, 3, 2, 1, 1])) % 10 == 0
    }

    private static func isNRIC(_ text: String) -> Bool {
        guard let prefix = text.first, let check = text.last, let values = digits(text.dropFirst().dropLast()) else { return false }
        let sum = weighted(values, [2, 7, 6, 5, 4, 3, 2]) + ("TG".contains(prefix) ? 4 : 0)
        return Array("ST".contains(prefix) ? "JZIHGFEDCBA" : "XWUTRQPNMLK")[sum % 11] == check
    }

    private static func isCURP(_ text: String) -> Bool {
        let alphabet = Array("0123456789ABCDEFGHIJKLMN&OPQRSTUVWXYZ")
        let values = text.dropLast().compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == 17, let check = text.last?.wholeNumberValue else { return false }
        return (10 - weighted(values, Array((2...18).reversed())) % 10) % 10 == check
    }

    private static func isCPF(_ text: String) -> Bool {
        guard let values = digits(text), values.count == 11, Set(values).count > 1 else { return false }
        func check(_ count: Int) -> Int { (11 - weighted(values.prefix(count), Array((2...count + 1).reversed())) % 11) % 11 % 10 }
        return values[9] == check(9) && values[10] == check(10)
    }

    private static func isNIR(_ text: String) -> Bool {
        // Corsica uses 2A and 2B in place of department digits.
        let number = text.replacingOccurrences(of: "2A", with: "19").replacingOccurrences(of: "2B", with: "18")
        guard number.count == 15, let body = Int(number.prefix(13)), let key = Int(number.suffix(2)) else { return false }
        return 97 - body % 97 == key
    }

    private static func isSpanishID(_ text: String) -> Bool {
        // A foreigner number starts with X, Y or Z standing for 0, 1 or 2.
        let body = text.dropLast().map { ["X": "0", "Y": "1", "Z": "2"][$0] ?? String($0) }.joined()
        guard let number = Int(body), let letter = text.last else { return false }
        return Array("TRWAGMYFPDXBNJZSQVHLCKE")[number % 23] == letter
    }

    private static func isGermanTaxID(_ text: String) -> Bool {
        guard let values = digits(text), values.count == 11 else { return false }
        // Among the first ten digits exactly one digit repeats, two or three times.
        let counts = Dictionary(grouping: values.prefix(10), by: { $0 }).values.map(\.count).filter { $0 > 1 }
        guard counts.count == 1, counts[0] <= 3 else { return false }
        return values.reduce(5) { (($0 == 0 ? 10 : $0) * 2 % 11 + $1) % 10 } == 1
    }

    private static func isPESEL(_ text: String) -> Bool {
        guard let values = digits(text), values.count == 11 else { return false }
        // The month carries the century as +20, +40, +60 or +80.
        guard isDate(month: (values[2] * 10 + values[3]) % 20, day: values[4] * 10 + values[5]) else { return false }
        return (10 - weighted(values, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]) % 10) % 10 == values[10]
    }

    private static func isPersonnummer(_ text: String) -> Bool {
        let last = String(text.filter(\.isNumber).suffix(10))
        guard let values = digits(last), values.count == 10 else { return false }
        // Coordination numbers add 60 to the day.
        return isDate(month: values[2] * 10 + values[3], day: (values[4] * 10 + values[5]) % 60) && passesLuhn(last)
    }

    private static func isBSN(_ text: String) -> Bool {
        guard let values = digits(text), values.count == 9, Set(values).count > 1 else { return false }
        return (weighted(values, [9, 8, 7, 6, 5, 4, 3, 2]) - values[8]) % 11 == 0
    }

    private static func isTFN(_ text: String) -> Bool {
        guard let values = digits(text), values.count == 9, Set(values).count > 1 else { return false }
        return weighted(values, [1, 4, 3, 7, 5, 8, 6, 9, 10]) % 11 == 0
    }

    private static func isIBAN(_ text: String) -> Bool {
        guard (15...34).contains(text.count) else { return false }
        // Move the country code and check digits to the end, read letters as 10...35, then take mod 97.
        var remainder = 0
        for character in text.dropFirst(4) + text.prefix(4) {
            guard character.isASCII, let value = character.wholeNumberValue ?? character.asciiValue.map({ Int($0) - 55 }) else { return false }
            remainder = (remainder * (value > 9 ? 100 : 10) + value) % 97
        }
        return remainder == 1
    }
}
