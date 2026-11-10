import Foundation
import WorkGraphCore

/// 그래프 노드 하나 (종류와 키)
struct NodeRef: Equatable, Hashable {
    let label: String
    let key: String
}

/// 업무가 아닌 노드의 상세: 업무 드로어 자리에 띄우고, 연결된 노드를 누르면 그 노드로 넘어간다 (‹ 뒤로)
extension AppState {
    /// 업무면 지금의 업무 상세, 그 밖의 노드면 노드 상세. fromDetail 이면 상세 안에서 연결된 노드로 넘어간 것이라 '뒤로'에 쌓고,
    /// 그래프에서 누른 것이면 새로 시작한다
    func openNodeDetail(_ ref: NodeRef, fromDetail: Bool = false) {
        if ref.label == NodeLabel.task { openTaskDetail(key: ref.key); return }
        if !fromDetail { nodeTrail = [] } else if let current = openNode, current != ref { nodeTrail.append(current) }
        openNode = ref
        taskDetailOpen = true
    }

    func backNode() {
        openNode = nodeTrail.popLast()
        if openNode == nil, selectedTaskId == nil { taskDetailOpen = false }
    }

    func nodeDetail(_ ref: NodeRef) -> NodeDetail? {
        guard let db else { return nil }
        return try? db.writer.read { try NodeDetailBuilder.build(label: ref.label, key: ref.key, conn: $0) }
    }
}
