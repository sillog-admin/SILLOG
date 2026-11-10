import CoreServices
import Foundation
import WorkGraphCore

/// AI 코딩 도구의 로컬 로그를 지켜보다가 새로 입력된 사용자 메시지를 DB 에 넣는다.
///   - Claude Code: ~/.claude/projects/**/*.jsonl  (파일마다 읽은 위치를 기억해 새 줄만 읽는다)
///   - Codex CLI:   ~/.codex/history.jsonl          (세션의 작업 폴더는 ~/.codex/sessions/**/rollout-*.jsonl 첫 줄에서)
/// 처음 켜면 최근 24시간 것만 가져온다. 몇 달치 과거 대화를 통째로 들이지 않기 위해서다.
public final class ChatLogWatcher: @unchecked Sendable {
    public static let backfillWindow: Double = 24 * 3600

    private let store: EventStore
    private let home: String
    private let queue = DispatchQueue(label: "workgraph.chatlogs", qos: .utility)
    private var stream: FSEventStreamRef?
    private var codexCwdBySession: [String: String] = [:]
    private var pending = false
    private(set) var ingestedTotal = 0

    public init(store: EventStore, home: String = NSHomeDirectory()) {
        self.store = store
        self.home = home
    }

    var claudeRoot: String { home + "/.claude/projects" }
    var codexHistory: String { home + "/.codex/history.jsonl" }
    var codexSessions: String { home + "/.codex/sessions" }

    public func start() {
        guard stream == nil else { return }
        let roots = [claudeRoot, home + "/.codex"].filter { FileManager.default.fileExists(atPath: $0) }
        queue.async { self.scanAll() }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ChatLogWatcher>.fromOpaque(info).takeUnretainedValue().scheduleScan()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// 파일 변경이 몰려와도 3초에 한 번만 훑는다.
    private func scheduleScan() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 3) {
            self.pending = false
            self.scanAll()
        }
    }

    func scanAll() {
        let since = Date().timeIntervalSince1970 - Self.backfillWindow
        var batch: [ChatMessage] = []
        var cursors: [String: Int64] = [:]
        do {
            for path in recentFiles(under: claudeRoot, suffix: ".jsonl", modifiedAfter: since) {
                guard let read = try newLines(of: path) else { continue }
                batch += ChatLogReader.parseClaude(lines: read.lines).filter { $0.ts >= since }
                cursors[path] = read.offset
            }
            if let read = try newLines(of: codexHistory) {
                refreshCodexCwdMap()
                batch += ChatLogReader.parseCodexHistory(lines: read.lines, cwdBySession: codexCwdBySession).filter { $0.ts >= since }
                cursors[codexHistory] = read.offset
            }
            let inserted = try store.insertChatMessages(batch, cursors: cursors)
            if inserted > 0 {
                ingestedTotal += inserted
                AppLog.write("AI 대화 \(inserted)건 읽음 (Claude Code / Codex CLI)")
            }
        } catch {
            AppLog.write("AI 대화 저장 실패: \(error)")
            scheduleScan()
        }
    }

    /// 지난번에 읽은 위치 다음부터 새 줄만. 파일이 줄어들었으면(교체됨) 처음부터.
    private func newLines(of path: String) throws -> (lines: [String], offset: Int64)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var offset = UInt64(try store.chatCursor(path: path) ?? 0)
        if offset > size { offset = 0 }
        guard offset < size else { return nil }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
        // 마지막 줄이 아직 쓰는 중이면(개행 없음) 다음에 읽는다
        var complete = data
        var consumed = data.count
        if data.last != UInt8(ascii: "\n"), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            complete = data[data.startIndex...lastNewline]
            consumed = complete.count
        } else if data.last != UInt8(ascii: "\n") {
            return nil
        }
        return (String(decoding: complete, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
                Int64(offset) + Int64(consumed))
    }

    private func recentFiles(under root: String, suffix: String, modifiedAfter: Double) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var result: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(suffix) else { continue }
            let path = (root as NSString).appendingPathComponent(relative)
            if let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970,
               modified >= modifiedAfter { result.append(path) }
        }
        return result
    }

    /// rollout 파일 첫 줄만 읽어 세션 → 작업 폴더 표를 만든다.
    private func refreshCodexCwdMap() {
        for path in recentFiles(under: codexSessions, suffix: ".jsonl", modifiedAfter: Date().timeIntervalSince1970 - 30 * 86_400) {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            let head = (try? handle.read(upToCount: 8_192)) ?? Data()
            try? handle.close()
            guard let firstLine = String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 1).first,
                  let meta = ChatLogReader.codexSessionMeta(firstLine: String(firstLine)), let cwd = meta.cwd else { continue }
            codexCwdBySession[meta.id] = cwd
        }
    }
}
