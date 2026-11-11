import Foundation
import SillogCore

/// 합성 평가 문항만 전달한다. 앱의 자료 조회·변경 도구는 실행하지 않는다.
@main
struct SkillEval {
    struct Input: Decodable { let system: String; let user: String }
    struct Answer: Decodable { let text: String }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw LLMError.backend("평가 모델을 지정하세요.") }
            let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
            let client = CodexResponsesClient(auth: CodexAuthManager(), model: CommandLine.arguments[1], reasoningEffort: "low", timeout: 90)
            let tool = ToolSpec(name: "submit_answer", description: "Return the complete answer in the text field.", parameters: .object([
                "type": "object", "properties": .object(["text": .object(["type": "string"])]), "required": .array(["text"]),
            ]))
            let result = try await client.callFunction(system: input.system, user: input.user, tool: tool)
            let answer = try JSONDecoder().decode(Answer.self, from: result.arguments)
            let output: [String: Any] = ["output": answer.text, "tokenUsage": ["prompt": result.promptTokens, "completion": result.completionTokens, "total": result.promptTokens + result.completionTokens]]
            let data = try JSONSerialization.data(withJSONObject: output)
            FileHandle.standardOutput.write(data)
        } catch {
            // 인증값·서버 응답 본문을 평가 로그에 남기지 않는다.
            FileHandle.standardError.write(Data("평가 호출 실패: \(String(describing: type(of: error)))\n".utf8))
            exit(1)
        }
    }
}
