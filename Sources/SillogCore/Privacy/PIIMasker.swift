import Foundation

// Identifier formats and check-digit rules come from the public specifications of each country.
// They were cross-checked against stdnum-js (MIT, Copyright © 2020, David Koblas) and
// validator.js (MIT, Copyright (c) 2018 Chris O'Hara). See THIRD_PARTY_NOTICES.md.

/// Replaces personal data and secrets with tags like `[PHONE]` before text leaves the device.
public enum PIIMasker {
    enum Kind: String, Sendable {
        case secret = "SECRET", id = "ID", email = "EMAIL", card = "CARD", phone = "PHONE", account = "ACCOUNT", address = "ADDRESS"
        case birth = "BIRTH", ip = "IP", handle = "HANDLE"
    }

    struct Rule {
        let name: String
        let kind: Kind
        let regex: NSRegularExpression
        let group: Int
        // A label that must end within the 40 characters before the match, where \z is the match start.
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
    // One password character. Quotes, brackets and ; or , count only inside a value, so a closing quote or the ;Database= of a connection string ends it.
    private static let secretChar = #"(?:[A-Za-z0-9_\-./+=!@#$%^&*~]|(?![;,][A-Za-z_ ]{1,30}=)[;'?,:()<>\[\]{}|\\"`](?=[A-Za-z0-9_\-./+=!@#$%^&*~]))"#

    // Words that follow @ in code: attributes, decorators, CSS at-rules, doc tags, template directives and Slack broadcasts.
    private static let codeAtWords = [
        "objc", "nonobjc", "escaping", "autoclosure", "available", "main", "testable", "inlinable", "inline", "frozen", "unknown",
        "convention", "unchecked", "retroactive", "preconcurrency", "noescape", "differentiable", "derivative", "transpose",
        "nonexhaustive", "safe", "unsafe", "concurrent", "isolated", "lifetime", "section", "used", "export", "extern", "attached",
        "freestanding", "specialized", "warn_unqualified_access", "interface", "implementation", "end", "property", "synthesize",
        "dynamic", "selector", "protocol", "optional", "required", "encode", "try", "catch", "finally", "throw", "autoreleasepool",
        "synchronized", "import", "class", "public", "private", "protected", "package", "compatibility_alias",
        "staticmethod", "classmethod", "abstractmethod", "dataclass", "cached_property", "lru_cache", "cache", "wraps",
        "contextmanager", "asynccontextmanager", "total_ordering", "singledispatch", "overload", "override", "final", "unique",
        "fixture", "patch", "receiver", "login_required", "api_view", "csrf_exempt", "deprecated", "jit", "njit", "validator",
        "field_validator", "model_validator", "root_validator", "shared_task", "task", "tool", "retry", "timer",
        "media", "charset", "namespace", "supports", "document", "page", "font-face", "keyframes", "counter-style",
        "font-feature-values", "layer", "container", "scope", "starting-style", "tailwind", "apply", "screen", "variants",
        "responsive", "config", "theme", "source", "utility", "plugin", "custom-variant", "reference", "include", "mixin",
        "extend", "use", "forward", "each", "for", "if", "else", "elseif", "while", "function", "return", "returns", "content",
        "debug", "warn", "error", "at-root", "param", "type", "typedef", "prop", "example", "throws", "exception", "see",
        "since", "author", "version", "link", "inheritdoc", "readonly", "async", "callback", "template", "default", "module",
        "exports", "memberof", "description", "summary", "todo", "internal", "experimental", "beta", "alpha", "remarks", "file",
        "fileoverview", "license", "copyright", "ts-ignore", "ts-expect-error", "ts-nocheck", "ts-check", "jsx", "satisfies",
        "enum", "const", "var", "global", "event", "constructor", "implements", "abstract", "static", "method", "member", "name",
        "ignore", "requires", "yields", "typeparam", "api", "test", "get", "set", "field", "id", "relation", "map",
        "endif", "foreach", "endforeach", "endfor", "endwhile", "extends", "endsection", "yield", "csrf", "auth", "endauth",
        "push", "endpush", "stack", "php", "endphp", "isset", "switch", "case", "model", "using", "inject", "code", "layout",
        "defer", "placeholder", "loading", "echo", "channel", "here", "everyone", "all", "localhost", "latest", "next",
        "types", "babel", "angular", "vue", "nestjs", "mui", "emotion", "testing-library", "aws-sdk", "typescript-eslint", "eslint",
        "prefix", "base", "context", "graph", "vocab", "language", "list", "reverse", "nest", "included", "update",
        "brief", "note", "details", "warning", "retval", "tparam", "daily", "hourly", "weekly", "monthly", "yearly", "annually",
        "midnight", "reboot", "html", "render", "attach", "empty", "forelse", "endforelse", "unless", "endunless", "once", "stop",
        "show", "variant", "jest-environment", "vitest-environment",
    ]

    // Any word ending in 로 or 길 reads as a road, so a road number alone needs a region, a unit or a label.
    private static let kr = (
        region: #"(?<![가-힣])(?:(?:서울|부산|대구|인천|광주|대전|울산|경기|강원|충북|충남|전북|전남|경북|경남|제주|충청[남북]|전라[남북]|경상[남북])(?:특별자치도|특별시|광역시|시|도)?\h+(?:(?:[가-힣]{2,5}[시군구]|[중동서남북]구)(?:\h+|\h*\n\h*)){1,2}|세종(?:특별자치시|시)\h+)(?:[가-힣]{1,4}[읍면]\h+)?"#,
        // Words like 여자친구 also end in 구, so a district without its province needs a clean end after the number.
        district: #"(?<![가-힣])(?:[가-힣]{2,5}시\h+)?(?:[가-힣]{2,4}|[중동서남북])구\h+"#,
        // 으로 is a particle, never a road name.
        road: #"[가-힣][가-힣0-9]{0,14}(?<!으)[로길](?:\h?\d{1,4}번?길)?"#,
        dong: #"[가-힣][가-힣0-9]{0,8}(?:동|리|\d가)"#,
        number: #"\h?(?:산\h?)?\d{1,5}(?:-\d{1,4})?"#,
        // Only a particle may follow the number, so 바로 3분 and 배열로 3개 stay.
        end: #"(?=(?:에서|에|으로|로|이야|야|이에요|예요|입니다|이요|요)?(?![\d가-힣]))"#,
        unit: #"(?:(?:,?\h?(?:(?:\d{1,4}|[A-Z가나다라마바사])동\h?)?\d{2,5}호|,?\h?\d{1,4}동)(?!\d))?"#,
        note: #"(?:\h?\([가-힣][가-힣0-9,.\h]{0,20}\))?"#
    )

    // Earlier rules claim their characters first, so a phone number is never read as an account number.
    // Only formats with a distinct shape, a strong check digit or a label are listed, so plain numbers stay readable.
    // shortcut: no names, unlabelled bare road numbers or unlabelled bare IDs, add a local NER model for those.
    static let rules: [Rule] = [
        // Stops at the next BEGIN, or a page of BEGIN lines without END would rescan to the end from each one.
        Rule("private-key", .secret, #"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:(?!-----BEGIN )[\s\S])*?-----END [A-Z ]*PRIVATE KEY-----"#),
        // A value without both a letter and a digit is a page number or a stock code like ?code=005930.
        Rule("url-secret", .secret, #"(?i)[?&#;](?:access_token|id_token|refresh_token|token|auth|authorization|api_key|apikey|key|sig|signature|session|sessionid|sid|password|passwd|pw|secret|client_secret|code|x-amz-signature|x-amz-security-token|x-goog-signature)=([^&\s#"'<>;)]{6,})"#, group: 1,
             isValid: { $0.contains(where: \.isLetter) && $0.contains(where: \.isNumber) }),
        Rule("jwt", .secret, #"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        Rule("api-key", .secret, edge.start + #"(?:sk-[A-Za-z0-9_-]{20,}|(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|hf_[A-Za-z0-9]{30,}|npm_[A-Za-z0-9]{30,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|ya29\.[0-9A-Za-z_-]{20,}|GOCSPX-[A-Za-z0-9_-]{24,}|AccountKey=[A-Za-z0-9+/=]{30,})"#),
        // Consoles show a key's last few characters, as in sk-...AbCd.
        Rule("api-key-redacted", .secret, edge.start + #"(?:(?:sk|rk|pk)(?:-(?:proj|svcacct|admin|ant(?:-api\d\d)?|live|test))?[-_](?:(?:live|test)_)?|hf_|gh[pousr]_|github_pat_|glpat-|xox[abprs]-|npm_|AIza|AKIA)(?:\.{2,}|…|\*{3,}|•{3,}) ?[A-Za-z0-9_-]{2,12}"# + edge.end),
        // Org, project and key IDs shown next to API keys. Mixed case with a digit sets them apart from words.
        Rule("console-id", .secret, edge.start + #"(?:key|org|proj|user|sess|acct|svcacct)[_-](?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Z])[A-Za-z0-9]{12,40}"# + edge.end),
        Rule("bearer", .secret, #"(?i)\bbearer\s+([A-Za-z0-9._~+/=-]{20,})"#, group: 1),
        // Before email, which would take pass@host.
        Rule("url-credentials", .secret, #"://[^\s/:@]*:([^\s/@]+)@"#, group: 1),
        // A digit, or a symbol before a letter or digit, keeps "token: unlimited", "password: String!" and "password: @escaping" out, and [ is an earlier placeholder.
        Rule("key-value", .secret, #"(?i)(?:(?:api|access|private|secret|account)[_-]?key|secret|token|password|passwd|pwd|passcode|passphrase|pw|비밀번호)["']?(?:\s*[:=：]|\s+is)\s*["']?(?![@$/\[])((?="# + secretChar + #"{0,63}(?:\d|[!@#$%^&*~][A-Za-z0-9]))"# + secretChar + #"{8,})"#, group: 1),
        // Before email, which would take only g@gmail.com out of h***g@gmail.com.
        Rule("email-partial", .email, #"(?<![A-Za-z0-9._%+\-*])(?:[A-Za-z][A-Za-z0-9._%+\-]{3,}+@(?=[\s*]|$)\**(?:\.[A-Za-z*]{2,})*|[A-Za-z0-9][A-Za-z0-9._%+\-]*+\*[A-Za-z0-9._%+\-*]*+@[A-Za-z0-9*][A-Za-z0-9.*\-]*\.[A-Za-z]{2,})"#),
        // Starts only where a run of address characters starts, or a long run without @ is rescanned from every offset.
        Rule("email", .email, #"(?<![A-Za-z0-9._%+-])(?!git@)[A-Za-z0-9._%+-]++@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        // Mixed case without a digit, _ or - is an attribute like @MainActor, a digit-first name needs 4 letters so @60Hz stays, and a ] before @ is an earlier placeholder.
        Rule("handle", .handle, #"(?<![A-Za-z0-9가-힣._%+\-/@\\$`\]])@(?:(?![가-힣]{0,8}(?:역|도서관|층|센터|카페|식당|학식|공원|오전|오후)(?![가-힣A-Za-z0-9_]))[가-힣][가-힣A-Za-z0-9_]{1,29}|(?!(?:"# + codeAtWords.joined(separator: "|")
             + #")(?![A-Za-z0-9_.\-])|(?:app|api|router|bp|db|pytest|functools|typing|abc|torch|tf|jax|st|bot|client|celery|click|mock|unittest)\.|[a-z_]+\.(?:setter|getter|deleter)(?![A-Za-z0-9_]))"#
             + #"(?=[a-z0-9_.\-]++(?![A-Za-z0-9_])|[A-Za-z0-9_.\-]*[0-9_\-])(?![A-Za-z0-9_.\-]*\.(?:com|net|org|kr|edu|gov)(?![A-Za-z0-9_.\-]))"#
             + #"(?:[A-Za-z]|(?!0x)\d++(?=[A-Za-z]{4}))(?:[A-Za-z0-9_]|[.\-](?=[A-Za-z0-9_])){2,30}+(?![A-Za-z0-9_@/(]|:[A-Za-z]|[^\S\n]*=)"#
             + #"(?![^\S\n]*\n[^\S\n]*(?:@|(?:def|class|async|func|struct|enum|extension|protocol|actor|public|private|internal|fileprivate|open|final|static|override|var|let|init|fun|val|export|function|const|interface|abstract)\b)|[^\S\n]+(?:func|var|init|struct|enum|extension|protocol|actor|typealias|import|public|private|internal|fileprivate|nonisolated|override|static|dynamic|fun|val|void)\b))"#),
        // macOS names the Mac after its owner, as in Gildongs-MacBook-Pro, and the shell prints it in every prompt.
        Rule("mac-hostname", .id, #"(?<![A-Za-z0-9/-])(?:(?i:[A-Za-z0-9-]{0,40}(?:macbook|imac|mac-?mini|mac-?studio|mac-?pro)[A-Za-z0-9-]{0,20}\.local)|(?!Apple-)[A-Za-z0-9][A-Za-z0-9-]{0,40}-(?:MacBook(?:-?(?:Pro|Air))?|iMac(?:-?Pro)?|Mac-?mini|Mac-?Studio|Mac-?Pro)(?:-\d{1,3})?)(?![A-Za-z0-9-])"#),
        Rule("iban", .account, edge.start + #"[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?"# + edge.end, isValid: isIBAN),
        // Only a fifth 4-digit group marks a longer run, so 3개월 or 12/27 after a card still masks it.
        Rule("card", .card, run.start + #"(?:(?:\d{4}[- ]){3}\d{4}|\d{16}|3[47]\d{2}[- ]?\d{6}[- ]?\d{5})(?![\d-])(?! \d{4}(?![./:-]\d))"#, isValid: passesLuhn),
        // Receipts star out the middle digits, which leaves no check digit to test.
        Rule("card-partial", .card, run.start + #"\d{4}[- ][\dX*]{4}[- ][\dX*]{4}[- ][\dX*]{4}"# + run.end, isValid: { $0.contains { "*X".contains($0) } }),
        // No country code starts with 0, so +0.00123 is a number; backing off before -NNN keeps a following number whole.
        Rule("intl-phone", .phone, #"(?<![A-Za-z0-9+])\+(?!0)\d{1,3}[- .]?(?:\(\d{1,4}\)[- .]?)?\d(?:[- .]?\d){6,12}(?![\d%]|[-.]\d)"#),
        Rule("kr-phone", .phone, #"(?<![\d+-])82[- .]1[016789][- .]?\d{3,4}[- .]?\d{4}(?![\d-])|(?<![\d-])01[016789](?:\h{0,2}[-–ㅡ.]\h{0,2}|\h{1,2})?\d{3,4}(?:\h{0,2}[-–ㅡ.]\h{0,2}|\h{1,2})?\d{4}(?!\d)|(?<![\d-])0\d{1,2}-\d{3,4}-\d{4}(?![\d-])"#),
        // Before kr-account, which would read the 0502-0508 safe numbers as accounts.
        Rule("kr-phone-variant", .phone, #"(?<![\d.-])(?:\(0(?:2|3[1-3]|4[1-4]|5[1-5]|6[1-4]|70|1[016789])\) ?|0(?:2|3[1-3]|4[1-4]|5[1-5]|6[1-4]|70)(?:\) ?|[. ])|050[2-8][- .])\d{3,4}[- .]\d{4}(?![\d-])(?!\.\d)"#),
        // Shown with digits hidden, or cut at a line end.
        Rule("kr-phone-partial", .phone, #"(?<![\d-])01[016789][- .](?:[\d*Xx•●]{3,4}[- .][\d*Xx•●]{4}|\d{3,4}-(?=\s|$))(?![\d*Xx•●-])"#),

        // The back half is often shown partly hidden, as in 900101-1******.
        Rule("kr-rrn", .id, #"(?<!\d)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]) ?[-–－‐‑−—] ?(?:[1-8]\d{6}|[1-8]\d{0,5}[*●•]{1,6}|[*●•]{7})(?![\d*●•])"#),
        Rule("kr-rrn-bare", .id, #"(?<!\d)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]) ?[1-8]\d{6}(?!\d)"#, label: "주민|등록번호|외국인"),
        // Region code 11-28, or the region name on older licences.
        Rule("kr-driver", .id, run.start + #"(?:(?:1[1-9]|2[0-8])-|(?:서울|부산|경기|강원|충북|충남|전북|전남|경북|경남|제주|대구|인천|광주|대전|울산)[- ]?)\d{2}-\d{6}-\d{2}(?![\d-])"#),
        Rule("kr-driver-bare", .id, run.start + #"(?:1[1-9]|2[0-8]) ?\d{2} ?\d{6} ?\d{2}"# + run.end, label: "면허"),
        // Since 2021 the fifth character is a letter.
        Rule("kr-passport", .id, edge.start + #"[MSRGD](?:\d{8}|\d{3}[A-Z]\d{4})"# + edge.end, isValid: isPassport),
        // The label is in the pattern so only a few words may separate it from the date. 발생일 and 학생일 are not birthdays.
        Rule("birth-date", .birth, #"(?i)(?:생년월일|(?<![가-힣])생일|출생(?:연월)?일|(?<![a-z])(?:birth|dob(?![a-z])))[^\n\d]{0,12}?\n?[^\n\d]{0,6}?((?:19|20)\d{2} ?[./년-] ?\d{1,2} ?[./월-] ?\d{1,2}(?: ?일)?|(?:19|20)\d{6}|\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])|\d{1,2}[./-]\d{1,2}[./-](?:19|20)\d{2}|\d{2} ?[./-] ?\d{1,2} ?[./-] ?\d{1,2})(?!\d)"#, group: 1),
        // Area 000 and 666, group 00 and serial 0000 are never issued. Covers ITIN.
        Rule("us-ssn", .id, #"(?<![\d-])(?!000|666)\d{3}-(?!00)\d{2}-(?!0000)\d{4}(?![\d-])"#),
        Rule("cn-ric", .id, edge.start + #"\d{6}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]"# + edge.end, isValid: isChineseID),
        Rule("jp-mynumber", .id, run.start + #"\d{4}[- ]\d{4}[- ]\d{4}"# + run.end, label: "マイナンバー|個人番号|my ?number", isValid: isMyNumber),
        Rule("in-aadhaar", .id, run.start + #"[2-9]\d{3}[- ]\d{4}[- ]\d{4}"# + run.end, isValid: passesVerhoeff),
        Rule("in-pan", .id, edge.start + #"[A-Z]{5}\d{4}[A-Z]"# + edge.end),
        Rule("hk-hkid", .id, edge.start + #"(?!KB)[A-NP-Z]{1,2}\d{6}(?:\([0-9A]\)|[0-9A])"# + edge.end, isValid: isHKID),
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

        Rule("nanp-phone", .phone, run.start + #"(?:\(\d{3}\) ?\d{3}[- .]|\d{3}-\d{3}-|\d{3}\.\d{3}\.)\d{4}"# + #"(?![\d-])"#),
        // Spaces alone also join sizes like 768 512 2048, so that form needs a label.
        Rule("nanp-phone", .phone, run.start + #"\d{3} \d{3} \d{4}"# + #"(?![\d-])"#, label: "tel|phone|call|mobile|cell|contact|fax|전화|연락처|휴대폰|문의"),
        // Ten digits would also take ISBN-10 and business registration numbers. Letters at the edges rule out UUIDs.
        // Not a dated file name like 2026-11-12-001, nor a patent number like 10-2026-0123456.
        Rule("kr-account", .account, #"(?<![0-9A-Za-z-])(?!(?:19|20)\d\d-\d\d-\d\d-)(?![1-4]0-(?:19|20)\d\d-\d{7}(?!\d))\d{2,6}-\d{2,6}-\d{2,8}(?:-\d{1,3})?(?![0-9A-Za-z-])"#, isValid: { (11...14).contains($0.count) }),
        // A bare account needs a bank word at most 20 characters before it; Unix times from 2017 to 2033 and amounts stay.
        Rule("kr-account-label", .account, #"(?<![0-9A-Za-z.-])(?!1[5-9](?:\d{8}|\d{11})(?!\d))\d{10,14}(?![0-9A-Za-z.-])(?![원명개건회])"#,
             label: #"(?:계좌|통장|입금|송금|이체|예금주|은행|뱅크|카뱅|account|농협|국민|신한|우리|하나|기업|카카오|토스|새마을|우체국)[^\n]{0,20}\n?\z"#),
        // Private and reserved ranges name no one; Chrome/120.0.0.0, cu12==9.1.0.70 and 1.1.1.1 are versions, sections or public DNS.
        Rule("ipv4", .ip, #"(?<![A-Za-z0-9.])(?<![A-Za-z]/)(?<![A-Za-z]\d{1,3}(?:==|-))(?<![Vv]ersion )(?<![Vv]ersion: )(?!(?:0|10|127)\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.|192\.168\.|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|(?:22[4-9]|2[3-5]\d)\.)(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\d|\.\d)"#, isValid: { $0.count > 4 }),
        // Global unicast 2000::/3 only, so ::1, fe80::, fd00:: and Python slices like [1::2] stay.
        Rule("ipv6", .ip, #"(?<![0-9A-Za-z:.])[23][0-9A-Fa-f]{3}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Za-z:]|\.\d)"#, isValid: isIPv6),

        // Label rules come after the shape rules so a code label never takes the first group of a card or phone number.
        // A Korean password or code right after its label: 비번은 1004야, 인증번호 : 5808b4f87d73. A year like 2026.03.11 is a date.
        Rule("kr-key-value", .secret, #"(?:(?<![A-Za-z])P[/.]?W(?![A-Za-z])|비밀\s?번호|비번|패스워드|암호|핀\s?번호|PIN\s?번호|인증\s?번호|인증\s?코드|보안\s?코드|복구\s?코드|일회용\s?코드|OTP)(?:\s*[:=：]|\s*(?:은|는|이|가|도))?\s*(?:["'`‘“(]|\[(?!\d{4,8}\]))?(?!(?:19|20)\d\d[./-])(?!(?i:aes|rsa|sha|des|3des|hmac|ecdsa|ecdh|chacha|md5)[-_]?\d)((?=[A-Za-z0-9!@#$%^&*._-]{0,39}\d)[A-Za-z0-9!@#$%^&*._-]{3,39}[A-Za-z0-9!@#$%^&*_-])(?![ \t]\d)(?=\s|$|[.,)\]!?'"`’”]|입니다|이에요|예요|이야|야|요|이고|이며|이다|로|으로|를|을|임|인데|라고|이라고|[~ㅋㅎ]|고(?![가-힣])|라서|니까|이니까|에요)"#, group: 1),
        // A verification code a few characters after its label, as in 인증번호 [482913]. Dates, times and counted units are not codes.
        Rule("otp", .secret, #"(?i)(?<![A-Za-z])(?:인증\s?번호|인증\s?코드|확인\s?코드|보안\s?코드|일회용\s?(?:비밀번호|코드)|verification code|security code|login code|sign-?in code|one-time code|otp|pin)(?![A-Za-z])[^\n\d]{0,15}?(?<![.-])(\d{4,8})(?![0-9A-Za-z-])(?![.:/ ]\d)(?![년월일시분초자원회개번])"#, group: 1),
        // A code before its label: 123456은 인증번호입니다, G-382910 is your Google verification code.
        Rule("otp-before", .secret, #"(?<![0-9A-Za-z.-])(?:G-)?\d{4,8}(?=\s?(?:은|는|이|가|을|를)?(?:\((?:은|는|이|가)\))?\s?(?:(?:Google|구글)\s?)?(?:인증\s?번호|인증\s?코드|(?i:is your (?:[A-Za-z-]+ ){0,3}code)))"#),
        // Order, booking, receipt and licence numbers. Unlabelled, the same shape is a file name like IMG_123456.
        Rule("labeled-id", .id, #"(?<![A-Za-z0-9_-])(?:(?:19|20)\d{2}-)?[A-Z]{2,8}[-_][A-Z]?\d{6,12}(?:[-_][A-Za-z0-9]{2,12})*+(?![A-Za-z0-9_-])"#, label: #"번호|No\.|number"#),
        // Student, staff and member numbers are bare digits, so only the label marks them.
        Rule("kr-member-id", .id, #"(?<![A-Za-z0-9.-])(?!(?:19|20)\d{2}-\d{1,2}-\d{1,2}(?!\d))(?:\d{6,12}|\d{2,4}(?:-\d{1,8}){1,2})(?![A-Za-z0-9-])(?!\.\d)"#,
             label: #"(?:학번|사번|교번|직번|수험\s?번호|회원\s?번호|고객\s?번호|사원\s?번호|student\s?(?:id|no|number)|employee\s?(?:id|no|number))[^\n]{0,20}\n?\z"#, isValid: { $0.count >= 6 }),
        // The value must follow its label, so 아이디 컬럼은 user_id stays; a digit or _ keeps words like Login out.
        Rule("labeled-handle", .handle, #"(?i:아이디(?!어)|카톡\s?(?:id|아이디)|카카오톡\s?(?:id|아이디)|kakao\s?(?:talk\s?)?id|인스타\s?(?:id|아이디)|instagram\s?id)\s*(?:\([^)\n]{0,12}\))?\s*(?:[:：]|은|는|이|가)?\s*((?<![A-Za-z0-9._%+\-@/])(?=[A-Za-z0-9._\-]*[0-9_])[A-Za-z][A-Za-z0-9][A-Za-z0-9._\-]{2,28}+(?![A-Za-z0-9_@/(\-]))"#, group: 1),
        // After 아이디: a letter-only value is an ID too.
        Rule("labeled-handle", .handle, #"(?<=아이디\h?[:：]\h?)[A-Za-z][A-Za-z0-9._\-]{3,29}+(?![A-Za-z0-9_@/(\-])"#),
        // Unknown-format tokens; a / = . or : before one marks a URL path, query value, domain or ID prefix.
        Rule("tokenish", .secret, #"(?<![A-Za-z0-9_+/=.@:-])(?<!base64,)(?<!ssh-rsa )(?<!ssh-ed25519 )(?!sha(?:256|384|512)-)[A-Za-z0-9_+/=-]{24,}(?![A-Za-z0-9_+/=-])"#, isValid: isTokenish),

        // Separate rules, as one alternation runs several times slower in ICU; they run before the region-dependent detector.
        Rule("kr-road-address", .address, #"(?:(?<![\d-])[(\[]?\d{5}[)\]]?\h?)?"# + kr.region + "(?:" + kr.dong + "|" + kr.road + ")" + kr.number
             + #"(?!\d)(?:\h?번지)?"# + kr.unit + kr.note),
        Rule("kr-district-address", .address, kr.district + "(?:" + kr.dong + "|" + kr.road + ")" + kr.number + #"(?:\h?번지)?"# + kr.end + kr.unit + kr.note),
        Rule("kr-road-unit", .address, #"(?<![가-힣0-9])(?=[가-힣][가-힣0-9]{0,20}\h?\d)"# + kr.road + kr.number + #",?\h?\d{1,4}동\h?\d{2,5}호(?!\d)"# + kr.note),
        // 메모리 100번지 is a memory address.
        Rule("kr-jibun", .address, #"(?<![가-힣])(?=[가-힣][가-힣0-9]{0,10}\h?(?:산\h?)?\d)[가-힣][가-힣0-9]{0,9}(?:동|읍|면|(?<!메모)리|\d가)\h?(?:산\h?)?\d{1,5}(?:-\d{1,5})?\h?번지"#),
        // A complex name alone is shared by thousands of homes, so it needs its 동 or 호; the lookahead keeps the name list cheap.
        Rule("kr-apartment", .address, #"(?<![가-힣A-Za-z0-9])(?=[가-힣A-Za-z0-9-]{2,28}\h?(?:[A-Z가나다라마바사]\h?동\h?)?\d)[가-힣A-Za-z0-9]{0,12}(?:아파트|빌라|오피스텔|맨션|하이츠|빌리지|푸르지오|자이|래미안|힐스테이트|아이파크|e편한세상|이편한세상|롯데캐슬|더샵|센트레빌|휴먼시아|위브|데시앙|비발디|베르디움|꿈에그린|스위첸|리슈빌|예미지|수자인|하늘채|해링턴|스타힐스|S-클래스|써밋|트리지움|아너스빌|어울림|코아루|파밀리에|에코델타|스카이뷰|센트럴|포레스트|더퍼스트|하이빌|그린빌|타운하우스|주공|임대)[가-힣A-Za-z0-9]{0,8}(?:\h?\d{1,4}\h?(?:단지|차))?\h?(?:\d{1,4}\h?동(?:\h?\d{1,5}\h?호)?|(?:[A-Z가나다라마바사]\h?동\h?)?\d{3,4}\h?호)(?!\d)"#),
        // A room number alone like 공학관 302호 or KTX 105호 is not a home, so 호 needs its 동.
        Rule("kr-unit", .address, #"(?<![\d가-힣])\d{1,4}동\h?\d{2,5}호(?!\d)"#),
        Rule("kr-road-number", .address, #"(?<![가-힣0-9])(?=[가-힣][가-힣0-9]{0,20}\h?\d)"# + kr.road + kr.number + kr.end + kr.unit + kr.note,
             label: #"주소|배송지|자택|거주지|사는\h?곳|우리\h?집|출발지|도착지|목적지"#),
        // A lot number right after an address label, as in 주소: 역삼동 123-45.
        Rule("kr-road-number", .address, #"(?<=(?:주소|배송지|자택|거주지)\h?[:：]?\h?)(?:[가-힣]{1,4}[읍면]\h+)?"# + kr.dong + kr.number + kr.end + kr.unit + kr.note),
        Rule("kr-zip", .address, #"(?<![\d.:/-])\d{5}(?![\d.:/-])"#, label: #"우편|\(우\)|우\)"#),
    ]

    // Set from the app setting. Off sends text as recorded.
    nonisolated(unsafe) public static var enabled = true

    // shortcut: addresses outside the Korean rules depend on the Mac's region, replace with a local model for even coverage.
    private static let addresses = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)
    private static let numberRun = try! NSRegularExpression(pattern: #"(?<!\S)\d+(?:[^\S\n]+\d+){3,}(?!\S)"#)
    // Romanized Korean roads like 12, Teheran-ro 34beon-gil, which the detector misses when a form puts the road on its own line.
    private static let romanRoad = try! NSRegularExpression(pattern: #"(?<![0-9A-Za-z.-])\d{1,5}(?:-\d{1,4})?,?\h+(?:[A-Z][a-z]+(?:[ -][a-z]+)?-(?i:daero|ro|gil))(?:\h\d{1,4}(?i:beon)?-?(?i:gil))?|[A-Z][a-z]+(?:[ -][a-z]+)?-(?i:daero|ro|gil)(?:\h\d{1,4}(?i:beon)?-?(?i:gil))?\h\d{1,5}(?:-\d{1,4})?(?![0-9A-Za-z-])"#)

    /// Args: text is any text bound for an external model.
    /// Returns: the text with each match replaced by its tag, for example `[PHONE]`. Unchanged when `enabled` is false.
    public static func mask(_ text: String) -> String {
        guard enabled else { return text }
        // macOS hands file names back decomposed, and the Korean rules match only composed syllables.
        let text = text.precomposedStringWithCanonicalMapping
        let result = NSMutableString(string: text)
        for item in matches(in: text).sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: item.range, with: "[\(item.kind.rawValue)]")
        }
        return result as String
    }

    /// Args: original is the text to scan; the ranges index it.
    /// Returns: non-overlapping matches with the rule that found each one.
    static func matches(in original: String) -> [(range: NSRange, kind: Kind, rule: String)] {
        // Full-width ASCII maps one-to-one in UTF-16, so the rules read ０１０ as 010 and ranges still fit the original.
        let text = String(String.UnicodeScalarView(original.unicodeScalars.map { (0xFF01...0xFF5E).contains($0.value) ? Unicode.Scalar($0.value - 0xFEE0)! : $0 }))
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
        // The detector slows sharply on runs of bare numbers and on long lines, so it reads a blanked copy in short chunks.
        let blanked = NSMutableString(string: text)
        for match in numberRun.matches(in: text, range: whole) { blanked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length)) }
        let scan = blanked as String
        var start = 0
        while start < whole.length {
            var end = min(start + 1000, whole.length)
            if end < whole.length {
                let space = blanked.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: NSRange(location: start, length: end - start))
                if space.location != NSNotFound, space.location > start { end = space.location }
            }
            for match in addresses?.matches(in: scan, range: NSRange(location: start, length: end - start)) ?? [] { claim(match.range, .address, "address") }
            start = end
        }
        // After the detector, so its wider match with the district and postcode wins.
        for match in romanRoad.matches(in: text, range: whole) { claim(match.range, .address, "kr-road-roman") }
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

    // MARK: Shape checks

    private static func isPassport(_ text: String) -> Bool {
        // A letter and a date like D20261118 is a build or file stamp.
        guard let values = digits(text.dropFirst()), values.count == 8, [19, 20].contains(values[0] * 10 + values[1]) else { return true }
        return !isDate(month: values[4] * 10 + values[5], day: values[6] * 10 + values[7])
    }

    private static func isIPv6(_ text: String) -> Bool {
        // At most one "::", which stands for at least one zero group; without it all eight groups are written.
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        let groups = halves.flatMap { $0.isEmpty ? [] : $0.split(separator: ":", omittingEmptySubsequences: false) }
        return groups.allSatisfy { (1...4).contains($0.count) } && (halves.count == 2 ? groups.count <= 7 : groups.count == 8)
    }

    // Words, acronyms and date runs; when they make up much of a token it is a file name or an identifier.
    private static let words = try! NSRegularExpression(pattern: #"[A-Z]?[a-z]{3,}|[A-Z]{2,}(?=[A-Z][a-z]|_|$)|\d{6,8}"#)

    private static func isTokenish(_ text: String) -> Bool {
        // Hex is a hash or a UUID, and many underscores make a snake_case name.
        guard text.count <= 512, text.contains(where: \.isLowercase), text.contains(where: \.isUppercase), text.contains(where: \.isNumber),
              !text.allSatisfy(\.isHexDigit), text.filter({ $0 == "_" }).count * 4 <= text.count else { return false }
        let wordy = words.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).reduce(0) { $0 + $1.range.length }
        guard Double(wordy) < 0.45 * Double(text.count) else { return false }
        let entropy = Dictionary(text.map { ($0, 1) }, uniquingKeysWith: +).values.reduce(0.0) {
            let p = Double($1) / Double(text.count)
            return $0 - p * log2(p)
        }
        return entropy >= 3.6
    }
}
