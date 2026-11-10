import Foundation
import WorkGraphCore

/// 지우기 확인 창에 띄울 것. 업무면 같은 분야의 업무가 더 있을 때 분야째 지우기도 고를 수 있다
struct EraseAsk: Identifiable {
    let ref: NodeRef
    let report: TaskEraser.Report
    let theme: (title: String, key: String, tasks: Int)?
    var id: String { ref.label + "|" + ref.key }
}

/// 노드 지우기 (그래프 우클릭, 상세의 지우기 단추): 그 노드와 그 노드에서만 이어진 하위 노드, 그 노드가 찍힌 원시 기록까지 (NodeEraser). 되돌릴 수 없다
extension AppState {
    /// 확인 창에 보여 줄 수 (지우지 않는다)
    func erasePreview(_ ref: NodeRef) -> TaskEraser.Report? {
        guard let db else { return nil }
        let now = Date().timeIntervalSince1970, home = NSHomeDirectory()
        return try? db.writer.read { conn in try NodeEraser.erase(label: ref.label, key: ref.key, conn: conn, now: now, home: home, dry: true) }
    }

    /// 확인 창을 띄운다. 없는 노드나 업무 종류 같은 클래스는 띄우지 않는다
    func askErase(_ ref: NodeRef) {
        guard let report = erasePreview(ref), !report.title.isEmpty, report.erasable else { eraseAsk = nil; return }
        var theme: (title: String, key: String, tasks: Int)?
        if ref.label == NodeLabel.task {
            if taskList.isEmpty { refreshTasks() }
            if let title = taskList.first(where: { $0.key == ref.key })?.theme {
                let count = taskList.filter { $0.theme == title }.count
                let key = (try? db?.writer.read { try String.fetchOne($0, sql: "SELECT key FROM nodes WHERE label = ? AND title = ?", arguments: [NodeLabel.theme, title]) }) ?? nil
                if count > 1, let key { theme = (title, key, count) }
            }
        }
        eraseAsk = EraseAsk(ref: ref, report: report, theme: theme)
    }

    /// 지운다. excludeApp 이면 그 앱을 제외 앱에도 넣는다 (앞으로 기록 안 함). 정리가 도는 중이면 끝날 때까지 기다린다
    /// (도는 중인 정리가 지운 업무를 다시 만들지 않게). 끝나면 드로어를 닫고 목록·그래프를 다시 읽고, 지운 내용이 DB 파일에 남지 않게 뒤에서 정리(compact)한다
    func erase(_ ref: NodeRef, excludeApp: Bool = false) async {
        guard let db, !erasing else { return }
        erasing = true
        defer { erasing = false }
        eraseAsk = nil
        while batchRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
        let now = Date().timeIntervalSince1970, home = NSHomeDirectory()
        do {
            let report = try await db.writer.write { conn in try NodeEraser.erase(label: ref.label, key: ref.key, conn: conn, now: now, home: home, dry: false) }
            _ = TaskEraser.removeFiles(report.files, within: URL(fileURLWithPath: databasePath).deletingLastPathComponent().path)   // 이 DB 의 데이터 폴더(스크린샷 captures) 안의 것만
            AppLog.write("지움: \(ref.label) \(report.title) (원시 행 \(report.observations), 화면 카드 \(report.cards), 노드 \(report.nodes))")
        } catch {
            AppLog.write("지우기 실패: \(error.localizedDescription)")
            eraseError = "지우는 중 문제가 생겨 아무것도 지우지 않았어요. 다시 해도 안 되면 알려 주세요.\n(\(String(error.localizedDescription.prefix(160))))"
            return
        }
        if excludeApp, ref.label == NodeLabel.app, !settings.excludedBundles.contains(ref.key) {
            settings.excludedBundles.append(ref.key)
            if !isPreview { applySettings() }
        }
        if ref.label == NodeLabel.task || ref.label == NodeLabel.theme { selectedTaskId = nil }
        taskDetailOpen = false
        graphVersion += 1
        refreshTasks()
        refresh()
        if AppFeatures.calendarOn { CalendarService.shared.refresh() }
        let compacting = Task.detached { try TaskEraser.compact(db) }
        if case .failure(let error) = await compacting.result { AppLog.write("지운 뒤 DB 정리 실패: \(error.localizedDescription)") }
    }
}

/// 지우기 확인 창 글
enum EraseCopy {
    /// "원시 기록 103행, 화면 카드 18장, 요약 1개와 이 업무가 들어간 정리 기록의 원문을 지워요. 되돌릴 수 없어요."
    static func message(label: String, _ report: TaskEraser.Report) -> String {
        var parts: [String] = []
        if report.observations > 0 || label == NodeLabel.task || label == NodeLabel.theme { parts.append("원시 기록 \(report.observations)행") }
        if report.cards > 0 { parts.append("화면 카드 \(report.cards)장") }
        if report.chats > 0 { parts.append("AI 대화 \(report.chats)건") }
        if report.recordings > 0 { parts.append("녹음 \(report.recordings)개") }
        if report.digests > 0 { parts.append("요약 \(report.digests)개") }
        let end = " 되돌릴 수 없어요."
        switch label {
        case NodeLabel.task:
            return "\(listed(parts))\(and(parts.last ?? "")) 이 업무가 들어간 정리 기록의 원문을 지워요.\(end)"
        case NodeLabel.theme:
            let all = ["이 분야의 업무 \(report.tasks.count)개"] + parts
            return "\(listed(all))\(and(all.last ?? "")) 그 업무가 들어간 정리 기록의 원문을 지워요.\(end)"
        default:
            let below = max(0, report.nodes - 1)
            if below > 0 { parts.append("이 노드에서만 이어진 노드 \(below)개") }
            guard let last = parts.last else { return "이 노드와 그 연결을 지워요. 원시 기록은 따로 없어요.\(end)" }
            let head = parts.dropLast()
            return (head.isEmpty ? "" : "\(listed(Array(head)))\(and(head.last ?? "")) ") + "\(last)\(object(last)) 지워요.\(end)"
        }
    }

    private static func listed(_ parts: [String]) -> String { parts.joined(separator: ", ") }

    /// 마지막 글자가 받침 있는 한글인지
    static func hasBatchim(_ word: String) -> Bool {
        guard let scalar = word.unicodeScalars.last, (0xAC00...0xD7A3).contains(scalar.value) else { return false }
        return (scalar.value - 0xAC00) % 28 != 0
    }

    static func and(_ word: String) -> String { hasBatchim(word) ? "과" : "와" }
    static func object(_ word: String) -> String { hasBatchim(word) ? "을" : "를" }
}
