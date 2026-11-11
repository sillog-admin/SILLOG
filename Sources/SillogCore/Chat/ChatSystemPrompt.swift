import Foundation

/// 채팅 시스템 프롬프트. 지침 원문은 Prompts/chat-system-prompt.md에 두고, 끝의 실행 정보 블록만 요청마다 채운다.
struct ChatSystemPrompt: Sendable {
    let template: String
    let scope: ChatScope
    let chatModel: String
    let scheduled: Bool
    var skillInstructions = ""
    var project: ChatProject?
    var rememberedSources = ""
    /// 대화의 초점 설명 (ContextSearch.focusOutline). nil 이면 블록을 뺀다
    var focus: String?
    /// 원문이 남아 있는 첫 날. 정리한 적이 없으면 nil
    var rawRecordsSince: String?

    /// Args: 없음.
    /// Returns: 앱에 포함된 채팅 시스템 프롬프트 원문.
    /// Raises: 번들 리소스 누락·읽기 오류.
    static func template() throws -> String {
        guard let url = ChatSkill.resourceBundle.url(forResource: "chat-system-prompt", withExtension: "md", subdirectory: "Prompts") else { throw ChatToolError.unavailable("채팅 지침을 찾을 수 없습니다.") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Args: role은 하위 에이전트 역할(nil이면 사용자에게 답하는 주 에이전트), now·timeZone은 현재 시각이다.
    /// Returns: 실행 정보를 채운 시스템 프롬프트. 하위 에이전트는 위임받은 작업 문장만 보므로 스킬·프로젝트·기억 자료 블록을 뺀다.
    /// Raises: 없음.
    func render(role: String?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var omitted: Set<String> = []
        if role != nil || skillInstructions.isEmpty { omitted.insert("skill_instructions") }
        if role != nil || project == nil { omitted.insert("project") }
        if role != nil || focus == nil { omitted.insert("focus") }
        if role != nil || rememberedSources.isEmpty { omitted.insert("remembered_sources") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
        // 타입을 적고 식을 나눠 둔다: 한 덩어리 사전 리터럴은 Swift 6.2 에서 타입 계산 시간 초과로 빌드가 멈춘다
        let connectors = (scope.connectors + (scope.useGitHub ? ["github"] : [])).joined(separator: ", ")
        let raw: [String: String] = [
            "skill_instructions": skillInstructions,
            "project_title": project?.title ?? "", "project_goal": project?.goal ?? "",
            "project_memory_mode": project?.memoryMode.title ?? "", "project_instructions": project?.instructions ?? "",
            "use_activity": scope.useActivity ? "on" : "off", "connected_paths": scope.paths.joined(separator: ", "),
            "use_web": scope.useWeb ? "on" : "off", "connectors": connectors,
            "remembered_sources": rememberedSources, "focus_outline": focus ?? "",
            "current_time": formatter.string(from: now), "timezone": timeZone.identifier,
            "chat_model": chatModel, "run_mode": scheduled ? "scheduled" : "interactive", "agent_role": role ?? "main",
            "raw_records_since": rawRecordsSince ?? "all",
        ]
        let values = raw.mapValues { $0.isEmpty ? "none" : $0 }
        return Self.fill(template, omitting: omitted, values: values)
    }

    /// Args: template은 프롬프트 원문, omitted는 뺄 블록의 태그 이름, values는 {{이름}} 자리에 넣을 값이다.
    /// Returns: 태그만 있는 줄로 여닫는 블록을 빼고 값을 채운 문자열. 넣은 값 안의 {{…}}는 다시 바꾸지 않는다.
    /// Raises: 없음. 모르는 이름은 그대로 둔다.
    static func fill(_ template: String, omitting omitted: Set<String>, values: [String: String]) -> String {
        var lines: [Substring] = [], closing: String?, afterBlock = false
        for line in template.split(separator: "\n", omittingEmptySubsequences: false) {
            if let tag = closing {
                if line == tag { closing = nil; afterBlock = true }
                continue
            }
            if afterBlock { afterBlock = false; if line.isEmpty { continue } }
            if line.hasPrefix("<"), line.hasSuffix(">"), omitted.contains(String(line.dropFirst().dropLast())) {
                closing = "</" + line.dropFirst(); continue
            }
            lines.append(line)
        }
        var text = "", rest = lines.joined(separator: "\n")[...]
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            text += rest[..<open.lowerBound]
            text += values[String(rest[open.upperBound..<close.lowerBound])] ?? String(rest[open.lowerBound..<close.upperBound])
            rest = rest[close.upperBound...]
        }
        return text + rest
    }
}
