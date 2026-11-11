import Foundation

/// AI 코딩 도구의 로컬 로그에서 "사용자가 입력한 메시지"만 뽑는다.
/// - Claude Code: ~/.claude/projects/<프로젝트>/<세션>.jsonl 의 type=user 줄 (도구 결과, 서브에이전트, 주입된 안내는 제외)
/// - Codex CLI:  ~/.codex/history.jsonl (session_id, ts, text). cwd 는 ~/.codex/sessions/**/rollout-*.jsonl 의 session_meta 에서
public enum ChatLogReader {
    public static let maxChars = 2_000

    static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseClaude(lines: [String]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "user",
                  (object["isSidechain"] as? Bool) != true,
                  let message = object["message"] as? [String: Any],
                  let sessionId = object["sessionId"] as? String,
                  let timestamp = object["timestamp"] as? String, let ts = parseDate(timestamp) else { continue }
            var texts: [String] = []
            if let content = message["content"] as? String {
                texts = [content]
            } else if let parts = message["content"] as? [[String: Any]] {
                texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            }
            guard let text = clean(texts.joined(separator: "\n")) else { continue }
            result.append(ChatMessage(ts: ts, tool: "claude-code", sessionId: sessionId, cwd: object["cwd"] as? String, text: text))
        }
        return result
    }

    public static func parseCodexHistory(lines: [String], cwdBySession: [String: String]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = object["session_id"] as? String,
                  let ts = (object["ts"] as? NSNumber)?.doubleValue,
                  let raw = object["text"] as? String, let text = clean(raw) else { continue }
            result.append(ChatMessage(ts: ts, tool: "codex-cli", sessionId: sessionId, cwd: cwdBySession[sessionId], text: text))
        }
        return result
    }

    public struct CodexSessionMeta: Equatable { public let id: String; public let cwd: String? }

    /// rollout 파일의 첫 줄(session_meta)에서 세션 id 와 작업 폴더를 읽는다.
    public static func codexSessionMeta(firstLine: String) -> CodexSessionMeta? {
        guard let data = firstLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = (payload["id"] as? String) ?? (payload["session_id"] as? String) else { return nil }
        return CodexSessionMeta(id: id, cwd: payload["cwd"] as? String)
    }

    /// 사람이 친 말만 남긴다. 도구가 주입한 안내(<...>로 시작), 중단 표시, 빈 문자열은 버리고 너무 긴 붙여넣기는 자른다.
    static func clean(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("[Request interrupted") else { return nil }
        return text.count > maxChars ? String(text.prefix(maxChars)) : text
    }

    static func parseDate(_ text: String) -> Double? {
        (isoWithFraction.date(from: text) ?? isoPlain.date(from: text))?.timeIntervalSince1970
    }
}
