import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 이미지를 받는 LLM (멀티모달)
public protocol VisionLLMClient: LLMClient {
    func callFunction(system: String, user: String, images: [(data: Data, mime: String)], detail: String, tool: ToolSpec) async throws -> LLMResult
}

extension CodexResponsesClient: VisionLLMClient {}

/// 대표 화면들을 한 번에 멀티모달 LLM 에 보내 화면 기억 카드를 만든다. 사실만 적게 하고 업무 판정은 하지 않는다.
public enum CardMaker {
    public struct Draft: Equatable, Sendable {
        public var activity: String
        public var content: [String]
        public var kind: String
        public var entities: [String: [String]]
    }

    public static let maxImages = 12
    public static let imageWidth = 1280

    static let system = """
    You look at screenshots of the user's Mac and write one memory card per screenshot, for a personal work log that will later be searched ("where was that table I saw", "what did I do Tuesday afternoon", "how did I fix that error").
    Each screenshot shows the front window (older ones show the whole screen). The FRONT window is the one named in the screenshot's info line (app, window title, url or file); describe that window. Other windows are context only; do not describe them.
    Write facts only: what is visible, not what it means. Do not guess why the user looked at it, what they are trying to achieve, or which project it belongs to. A subject mentioned on screen is not the user's activity.
    Do not interpret words: a name, abbreviation or slang word that could refer to more than one thing is copied as written, never replaced by what you think it refers to. Describe a subject only in words that appear on the screen.
    For each screenshot:
    - activity: one Korean sentence — the observable action in the front window (reading, writing, coding, chatting with an AI, watching, searching, filling a form …) and on what: the document or page by its title, or the conversation partner and the app. For a chat or message screen, name only the partner and the app, not what the conversation is about; the quoted messages carry the subject. No purpose words ("~하기 위해", "~을 조율하고", "~을 준비하며") unless the screen literally shows that work being done.
    - content: concrete, searchable content visible in the front window, in the original language. For chats and messages (AI chats too), quote the visible messages verbatim with the sender ("이름: 메시지"), up to the 12 most recent, most recent last; do not paraphrase or summarize them. For other screens, 2-6 short lines: the document or page title, headings, key sentences, numbers and table values, code identifiers, commands and their output, error messages, questions the user typed. No UI chrome (menus, sidebars, tabs, toolbars).
    - kind: one of document, code, web, ai_chat, message, video, tool (settings, dashboards, file browsers, installers), none (nothing to read: lock screen, loading, blank).
    - entities: named things visible in the front window — documents (file names, document or page titles), people (names, handles), code (functions, classes, files, packages), errors (error messages), numbers (values with their meaning, e.g. "AUC 0.93"), links (URLs or site names). Empty lists when none.
    Write nothing you cannot see. Always answer by calling write_cards with the cards in the order of the screenshots.
    """

    static var tool: ToolSpec {
        let list: JSONValue = .object(["type": "array", "items": .object(["type": "string"])])
        return ToolSpec(name: "write_cards", description: "Memory cards, one per screenshot, in order.", parameters: .object([
            "type": "object",
            "properties": .object(["cards": .object(["type": "array", "items": .object([
                "type": "object",
                "properties": .object([
                    "image": .object(["type": "integer", "description": "1부터 시작하는 스크린샷 번호"]),
                    "activity": .object(["type": "string"]),
                    "content": list,
                    "kind": .object(["type": "string", "enum": .array(ScreenCard.kinds.map { .string($0) })]),
                    "entities": .object(["type": "object", "properties": .object([
                        "documents": list, "people": list, "code": list, "errors": list, "numbers": list, "links": list,
                    ])]),
                ]),
                "required": .array(["image", "activity", "content", "kind", "entities"]),
            ])])]),
            "required": .array(["cards"]),
        ]))
    }

    static func userMessage(_ groups: [KeyframeSelector.Group]) -> String {
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.dateFormat = "HH:mm"
        var lines = ["SCREENSHOTS (in order):"]
        for (index, group) in groups.enumerated() {
            let shot = group.representative
            lines.append("image \(index + 1): app \(group.appName) | window title: \(group.title ?? "-") | url or file: \(group.uri ?? "-") | time \(clock.string(from: Date(timeIntervalSince1970: shot.ts)))")
        }
        return lines.joined(separator: "\n")
    }

    /// 파일을 imageWidth 로 줄여 JPEG 로
    public static func loadImage(path: String, maxWidth: Int = imageWidth) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxWidth,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 묶음 순서대로 카드 초안. 이미지를 못 읽은 묶음은 건너뛰고, 돌려주는 배열의 순서는 입력 순서를 따른다 (nil = 못 만듦)
    public static func make(_ groups: [KeyframeSelector.Group], llm: any VisionLLMClient,
                            load: (String) -> Data? = { loadImage(path: $0) }) async throws -> (drafts: [Draft?], result: LLMResult?) {
        var sent: [(index: Int, data: Data)] = []
        for (index, group) in groups.enumerated() {
            if let data = load(group.representative.path) { sent.append((index, data)) }
        }
        guard !sent.isEmpty else { return (Array(repeating: nil, count: groups.count), nil) }
        let sentGroups = sent.map { groups[$0.index] }
        let result = try await llm.callFunction(system: system, user: userMessage(sentGroups), images: sent.map { ($0.data, "image/jpeg") }, detail: "auto", tool: tool)
        var drafts: [Draft?] = Array(repeating: nil, count: groups.count)
        let parsed = (try? JSONSerialization.jsonObject(with: result.arguments) as? [String: Any])?["cards"] as? [[String: Any]] ?? []
        for (position, card) in parsed.enumerated() {
            let number = (card["image"] as? NSNumber)?.intValue ?? (position + 1)
            guard number >= 1, number <= sent.count else { continue }
            let activity = (card["activity"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !activity.isEmpty else { continue }
            var entities: [String: [String]] = [:]
            for (key, value) in card["entities"] as? [String: Any] ?? [:] {
                let items = (value as? [Any] ?? []).compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !items.isEmpty { entities[key] = items }
            }
            let kind = card["kind"] as? String ?? "none"
            drafts[sent[number - 1].index] = Draft(activity: activity,
                                                  content: (card["content"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty },
                                                  kind: ScreenCard.kinds.contains(kind) ? kind : "none", entities: entities)
        }
        return (drafts, result)
    }

    public static func entitiesJSON(_ entities: [String: [String]]) -> String {
        (try? JSONSerialization.data(withJSONObject: entities, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
