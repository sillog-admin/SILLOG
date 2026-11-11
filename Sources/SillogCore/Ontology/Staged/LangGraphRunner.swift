import Foundation
import LangGraph

/// 그래프 정의를 돌리는 실행기. 라이브러리를 바꿔도 단계 코드는 그대로 둔다
public protocol PipelineRunner: Sendable {
    func run(_ graph: PipelineGraph, _ state: JudgeState, llm: any LLMClient) async throws -> JudgeState
}

/// LangGraph-Swift 로 돌린다. LangGraph 는 상태를 [String: Any] 로 다루므로, 타입 있는 JudgeState 하나를 "judge" 키에 넣고 꺼낸다
public struct LangGraphRunner: PipelineRunner {
    struct Carrier: AgentState {
        var data: [String: Any]
        init(_ initState: [String: Any]) { data = initState }
        var judge: JudgeState? { data["judge"] as? JudgeState }
    }

    public init() {}

    public func run(_ graph: PipelineGraph, _ state: JudgeState, llm: any LLMClient) async throws -> JudgeState {
        let workflow = StateGraph { Carrier($0) }
        for node in graph.nodes {
            try workflow.addNode(node.id) { carrier in
                guard let current = carrier.judge else { throw PipelineError.lostState }
                return ["judge": try await node.run(current, llm)]
            }
        }
        try workflow.addEdge(sourceId: START, targetId: graph.entry)
        for node in graph.nodes {
            let mapping = Dictionary(node.edges.map { ($0.label, $0.target == PipelineGraph.end ? END : $0.target) }, uniquingKeysWith: { first, _ in first })
            try workflow.addConditionalEdge(sourceId: node.id, condition: { carrier in
                guard let current = carrier.judge else { throw PipelineError.lostState }
                return node.route(current)
            }, edgeMapping: mapping)
        }
        let result = try await workflow.compile().invoke(.args(["judge": state]))
        guard let final = result.judge else { throw PipelineError.lostState }
        return final
    }
}
