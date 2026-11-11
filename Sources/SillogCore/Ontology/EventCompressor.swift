import Foundation

/// LLM에 보내는 한 줄. 연속된 같은 컨텍스트를 하나로 합친 결과다.
public struct ActivityRow: Codable, Equatable, Sendable {
    public var row: Int
    public var start: Double
    public var end: Double
    public var dwell: Int
    public var app: String
    public var appBundle: String
    public var title: String?
    public var uri: String?
    public var type: String?
    public var projectKey: String?
    public var projectTitle: String?
    public var snippet: String?
    public var observationIds: [Int64]
    /// 창 기록이 아닌 행인지: AI 도구와의 대화 또는 녹음 (체류시간 없음, 시간 집계·앱 노드·화면 카드에 들어가지 않음)
    public var isChat: Bool = false
    /// 이 행에 들어간 대화 메시지 id (처리 완료 표시용)
    public var chatMessageIds: [Int64] = []
    /// 이 행에 들어간 녹음 id (처리 완료 표시용)
    public var recordingIds: [Int64] = []

    public init(row: Int, start: Double, end: Double, dwell: Int, app: String, appBundle: String, title: String?, uri: String?, type: String?,
                projectKey: String?, projectTitle: String?, snippet: String?, observationIds: [Int64], isChat: Bool = false, chatMessageIds: [Int64] = [],
                recordingIds: [Int64] = []) {
        self.row = row; self.start = start; self.end = end; self.dwell = dwell; self.app = app; self.appBundle = appBundle
        self.title = title; self.uri = uri; self.type = type; self.projectKey = projectKey; self.projectTitle = projectTitle
        self.snippet = snippet; self.observationIds = observationIds; self.isChat = isChat; self.chatMessageIds = chatMessageIds
        self.recordingIds = recordingIds
    }
}

public enum EventCompressor {
    /// - maxGap: 다음 행까지의 간격 상한(초). 수집기가 60초마다 생존 신호를 남기므로,
    ///   이보다 긴 간격은 "앱이 꺼져 있었거나 잠자기"로 보고 체류시간에 넣지 않는다.
    public static func compress(_ observations: [Observation], idle: [IdleSpan], texts: [Int64: String], windowEnd: Double,
                                home: String, fileExists: (String) -> Bool, maxRows: Int, maxGap: Double,
                                snippetChars: Int, snippetTopN: Int) -> [ActivityRow] {
        let sorted = observations.sorted { ($0.ts, $0.id ?? 0) < ($1.ts, $1.id ?? 0) }
        guard !sorted.isEmpty else { return [] }

        struct Draft {
            var contextKey: String
            var first: Observation
            var start: Double
            var end: Double
            var dwell: Double
            var ids: [Int64]
            var textId: Int64?
        }
        var drafts: [Draft] = []
        for (index, obs) in sorted.enumerated() {
            let rawEnd = index + 1 < sorted.count ? sorted[index + 1].ts : max(windowEnd, obs.ts)
            let end = min(rawEnd, obs.ts + maxGap)
            let dwell = activeSeconds(from: obs.ts, to: end, idle: idle, openEnd: windowEnd)
            let ids = obs.id.map { [$0] } ?? []

            if var last = drafts.last, last.contextKey == obs.contextKey {
                last.end = end; last.dwell += dwell; last.ids += ids
                if last.textId == nil { last.textId = obs.textId }
                drafts[drafts.count - 1] = last
            } else if dwell < 2, var last = drafts.last {
                // 스쳐 지나간 창은 앞 행에 흡수한다 (행은 남기지 않되 처리 완료 표시는 되도록 id는 보존).
                last.end = end; last.dwell += dwell; last.ids += ids
                drafts[drafts.count - 1] = last
            } else {
                drafts.append(Draft(contextKey: obs.contextKey, first: obs, start: obs.ts, end: end, dwell: dwell, ids: ids, textId: obs.textId))
            }
        }

        var rows: [ActivityRow] = drafts.prefix(maxRows).enumerated().map { index, draft in
            let obs = draft.first
            let classified = RuleClassifier.classify(appBundle: obs.appBundle, appName: obs.appName, windowTitle: obs.windowTitle,
                                                     url: obs.url, docPath: obs.docPath, home: home, fileExists: fileExists)
            return ActivityRow(row: index + 1, start: draft.start, end: draft.end, dwell: Int(draft.dwell.rounded()),
                               app: obs.appName, appBundle: obs.appBundle,
                               title: classified?.title ?? RuleClassifier.cleanTitle(obs.windowTitle),
                               uri: classified?.key, type: classified?.subtype,
                               projectKey: classified?.projectKey, projectTitle: classified?.projectTitle,
                               snippet: nil, observationIds: draft.ids)
        }

        // 화면 텍스트는 체류가 긴 행에만 붙인다 (비용·프라이버시).
        let textByRow = Dictionary(uniqueKeysWithValues: drafts.prefix(maxRows).enumerated().compactMap { index, draft -> (Int, String)? in
            guard let id = draft.textId, let text = texts[id], !text.isEmpty else { return nil }
            return (index, text)
        })
        let top = textByRow.keys.sorted { (rows[$0].dwell, -$0) > (rows[$1].dwell, -$1) }.prefix(max(0, snippetTopN))
        for index in top {
            rows[index].snippet = makeSnippet(textByRow[index] ?? "", limit: snippetChars)
        }
        return rows
    }

    /// AI 대화와 받아쓴 녹음을 행으로 끼워 넣는다. 같은 세션의 메시지는 한 행, 녹음은 한 건에 한 행.
    /// 체류시간은 0 이라 앱 시간 집계를 건드리지 않는다 (녹음은 창 기록과 겹친다). 창보다 오래된 것은 창 시작 시각에 놓는다.
    /// 사용자가 AI 에게 한 말은 업무 의도를 그대로 담고 있어서 LLM 이 업무 제목·주제를 잡는 데 가장 강한 단서다.
    public static func merge(_ rows: [ActivityRow], chats: [ChatMessage], recordings: [Recording] = [], home: String, fileExists: (String) -> Bool,
                             snippetChars: Int) -> [ActivityRow] {
        guard !chats.isEmpty || !recordings.isEmpty else { return rows }
        // 늦게 읽힌 메시지(창보다 오래된 것)는 창 시작 시각에 놓는다. 세션 시작이 과거로 밀리는 것을 막는다.
        let extraStarts: [Double] = chats.map(\.ts) + recordings.map(\.startedAt)
        let extraEnds: [Double] = chats.map(\.ts) + recordings.map { $0.endedAt ?? $0.startedAt }
        let windowStart = rows.map(\.start).min() ?? extraStarts.min() ?? 0
        let windowEnd = rows.map(\.end).max() ?? extraEnds.max() ?? windowStart
        func clamp(_ ts: Double) -> Double { min(max(ts, windowStart), windowEnd) }
        var sessions: [String: [ChatMessage]] = [:]
        var order: [String] = []
        for message in chats.sorted(by: { $0.ts < $1.ts }) {
            let key = "\(message.tool)|\(message.sessionId)"
            if sessions[key] == nil { order.append(key) }
            sessions[key, default: []].append(message)
        }
        var chatRows: [ActivityRow] = order.compactMap { key in
            guard let messages = sessions[key], let first = messages.first, let last = messages.last else { return nil }
            let toolName = first.toolName
            let uri = "chat:\(first.tool):\(first.sessionId)"
            var snippet = ""
            for message in messages {
                let line = "「" + makeSnippet(message.text, limit: 240) + "」"
                if snippet.count + line.count > snippetChars * 2 { snippet += " …"; break }
                snippet += (snippet.isEmpty ? "" : " ") + line
            }
            var projectKey: String?, projectTitle: String?
            if let cwd = messages.compactMap(\.cwd).first, !cwd.isEmpty {
                let root = RuleClassifier.projectRoot(forFile: (cwd as NSString).appendingPathComponent("."), home: home, fileExists: fileExists) ?? cwd
                projectKey = URINormalizer.normalize(filePath: root, home: home)
                projectTitle = (root as NSString).lastPathComponent
            }
            return ActivityRow(row: 0, start: clamp(first.ts), end: max(clamp(last.ts), clamp(first.ts)), dwell: 0, app: toolName, appBundle: "chat.\(first.tool)",
                               title: "\(toolName): \(makeSnippet(first.text, limit: 60))", uri: uri, type: "AIChat",
                               projectKey: projectKey, projectTitle: projectTitle, snippet: snippet, observationIds: [], isChat: true,
                               chatMessageIds: messages.compactMap(\.id))
        }
        chatRows.removeAll { $0.snippet?.isEmpty ?? true }
        // 녹음: 받아쓴 글이 있는 것만. 요약 + 받아쓴 글 앞부분을 text: 로
        let recordingRows: [ActivityRow] = recordings.compactMap { recording in
            guard let id = recording.id, recording.hasTranscript else { return nil }
            let excerpt = makeSnippet(recording.transcript, limit: snippetChars * 2)
            var parts: [String] = []
            if let summary = recording.summary, !summary.isEmpty { parts.append("요약: " + makeSnippet(summary, limit: 200)) }
            if !excerpt.isEmpty { parts.append("「\(excerpt)」") }
            let start = clamp(recording.startedAt)
            let end = max(clamp(recording.endedAt ?? recording.startedAt), start)
            return ActivityRow(row: 0, start: start, end: end, dwell: 0, app: "녹음", appBundle: "sillog.recording",
                               title: recording.title ?? "녹음", uri: "recording:\(id)", type: "Recording",
                               projectKey: nil, projectTitle: nil, snippet: parts.joined(separator: " "), observationIds: [],
                               isChat: true, recordingIds: [id])
        }
        var merged = rows + chatRows + recordingRows
        merged.sort { ($0.start, $0.isChat ? 1 : 0) < ($1.start, $1.isChat ? 1 : 0) }
        for index in merged.indices { merged[index].row = index + 1 }
        return merged
    }

    static func activeSeconds(from start: Double, to end: Double, idle: [IdleSpan], openEnd: Double) -> Double {
        guard end > start else { return 0 }
        var idleTotal = 0.0
        for span in idle {
            let overlapStart = max(start, span.startTs)
            let overlapEnd = min(end, span.endTs ?? openEnd)
            if overlapEnd > overlapStart { idleTotal += overlapEnd - overlapStart }
        }
        return max(0, (end - start) - idleTotal)
    }

    static func makeSnippet(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }
}
