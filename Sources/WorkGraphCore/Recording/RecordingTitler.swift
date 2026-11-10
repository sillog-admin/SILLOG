import Foundation

/// 녹음 길이·시계 문구
public enum RecordingText {
    /// "45초", "2분", "52분 10초", "1시간 3분"
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)초" }
        if total < 3_600 {
            let minutes = total / 60, rest = total % 60
            return rest == 0 ? "\(minutes)분" : "\(minutes)분 \(rest)초"
        }
        let hours = total / 3_600, minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes)분"
    }

    /// 메뉴 막대의 지난 시간: "12:31", "1:02:03"
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3_600, minutes = (total % 3_600) / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
    /// 시각을 형식대로 (en_US_POSIX, 주어진 시간대). 예: "yyyy-MM-dd HH:mm" → "2026-10-10 15:32"
    public static func date(_ time: Double, _ pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }
}

/// 받아쓴 글에 제목과 한 줄 요약을 붙이고, 받아쓴 글 .md 를 만든다
public struct RecordingTitler: Sendable {
    public struct Naming: Equatable, Sendable {
        public var title: String
        public var summary: String?
        public init(title: String, summary: String?) { self.title = title; self.summary = summary }
    }

    /// 모델에 보내는 받아쓴 글 앞부분 길이
    public static let headChars = 4_000
    /// 폴더 추천에 넘기는 받아쓴 글 앞부분 길이
    public static let excerptChars = 800

    let llm: any LLMClient
    public init(llm: any LLMClient) { self.llm = llm }

    /// 받아쓴 글이 비었거나 모델이 실패하면 날짜 제목 ("녹음 2026-10-10 15-32")
    public func name(transcript: String, startedAt: Double, duration: Double, timeZone: TimeZone = .current) async -> Naming {
        let fallback = Naming(title: Self.fallbackTitle(startedAt: startedAt, timeZone: timeZone), summary: nil)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        do {
            let prompt = Self.prompt(transcript: transcript, startedAt: startedAt, duration: duration, timeZone: timeZone)
            let result = try await llm.callFunction(system: Self.system, user: prompt, tool: Self.tool)
            return Self.parse(result.arguments) ?? fallback
        } catch {
            AppLog.write("녹음 제목 짓기 실패: \(String(describing: error).prefix(200))")
            return fallback
        }
    }

    static let system = """
    You name a voice recording the user made on their Mac, from its transcript.
    The transcript comes from on-device speech recognition: some words may be misheard, and speakers are not marked.
    Give a short Korean title of about 20 characters that says what the recording is about, such as the course and topic of a lecture or the subject of a meeting. Do not put dates, times or the word 녹음 in the title.
    Give a one-sentence Korean summary of what was said.
    Always answer by calling name_recording.
    """

    static var tool: ToolSpec {
        ToolSpec(name: "name_recording", description: "Give the recording a title and a one-sentence summary.", parameters: .object([
            "type": "object",
            "properties": .object([
                "title": .object(["type": "string", "description": "short Korean title, about 20 characters"]),
                "summary": .object(["type": "string", "description": "one Korean sentence"]),
            ]),
            "required": .array(["title", "summary"]),
        ]))
    }

    static func prompt(transcript: String, startedAt: Double, duration: Double, timeZone: TimeZone) -> String {
        let recorded = "RECORDED: \(RecordingText.date(startedAt, "yyyy-MM-dd HH:mm", timeZone: timeZone)) (\(RecordingText.duration(duration)))"
        let label = transcript.count > headChars ? "TRANSCRIPT (first \(headChars) characters):" : "TRANSCRIPT:"
        return [recorded, label, String(transcript.prefix(headChars))].joined(separator: "\n")
    }

    static func parse(_ data: Data) -> Naming? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let quotes = CharacterSet(charactersIn: "\"'“”‘’「」『』").union(.whitespacesAndNewlines)
        let title = (object["title"] as? String ?? "").trimmingCharacters(in: quotes)
        guard !title.isEmpty else { return nil }
        let summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept: String? = (summary?.isEmpty ?? true) ? nil : summary
        return Naming(title: String(title.prefix(40)), summary: kept)
    }

    public static func fallbackTitle(startedAt: Double, timeZone: TimeZone) -> String {
        "녹음 " + RecordingText.date(startedAt, "yyyy-MM-dd HH-mm", timeZone: timeZone)
    }

    /// 파일 이름: 날짜 + 제목 + .md. 쓸 수 없는 글자는 빼고, 제목에 이미 날짜가 있으면 한 번만
    public static func fileName(title: String, startedAt: Double, timeZone: TimeZone) -> String {
        let day = RecordingText.date(startedAt, "yyyy-MM-dd", timeZone: timeZone)
        var base = sanitize(title)
        if base.isEmpty { base = fallbackTitle(startedAt: startedAt, timeZone: timeZone) }
        return (base.contains(day) ? base : "\(day) \(base)") + ".md"
    }

    /// `/ \ : * ? " < > |` 와 줄바꿈은 빈칸으로 바꾸고, 빈칸을 하나로, 앞뒤 점·빈칸은 뺀다 (60자까지)
    public static func sanitize(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let space: Unicode.Scalar = " "
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars { scalars.append(forbidden.contains(scalar) ? space : scalar) }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(trimmed.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// .md 본문: 제목, 녹음 시각과 길이, 요약, 받아쓴 글(발화마다 한 문단)
    public static func markdown(title: String, summary: String?, utterances: [String], startedAt: Double, duration: Double, timeZone: TimeZone) -> String {
        var lines: [String] = ["# \(title)", ""]
        lines.append("- 녹음: \(RecordingText.date(startedAt, "yyyy년 M월 d일 HH:mm", timeZone: timeZone)), \(RecordingText.duration(duration))")
        if let summary, !summary.isEmpty { lines.append("- 요약: \(summary)") }
        lines += ["", "## 받아쓴 글", ""]
        lines.append(utterances.joined(separator: "\n\n"))
        return lines.joined(separator: "\n") + "\n"
    }

    /// 받아쓴 글 .md 를 folder 에 만든다. 같은 이름이 있으면 " (2)" 를 붙인다. 만든 파일 주소
    public static func write(_ recording: Recording, into folder: URL, timeZone: TimeZone) throws -> URL {
        let title = recording.title ?? fallbackTitle(startedAt: recording.startedAt, timeZone: timeZone)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = fileName(title: title, startedAt: recording.startedAt, timeZone: timeZone)
        let base = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(counter)).md")
            counter += 1
        }
        let text = markdown(title: title, summary: recording.summary, utterances: recording.utterances,
                            startedAt: recording.startedAt, duration: recording.duration, timeZone: timeZone)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 폴더 추천에 넘기는 내용 발췌: 요약 + 받아쓴 글 앞 800자
    public static func excerpt(summary: String?, transcript: String) -> String {
        let head = String(transcript.replacingOccurrences(of: "\n", with: " ").prefix(excerptChars))
        guard let summary, !summary.isEmpty else { return head }
        return summary + "\n" + head
    }

}
