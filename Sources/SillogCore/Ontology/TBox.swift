import Foundation

/// 클래스 층(T-Box). 코드에 정의하고, 그래프에는 TaskType / ResourceType 노드로 시드한다.
/// 상위 클래스가 있어야 "참고자료에 쓴 시간" 같은 집계가 가능하다.
public enum TBox {
    public static let taskTypes: [(name: String, parent: String?)] = [
        ("정보수집", nil), ("문헌조사", "정보수집"), ("시장조사", "정보수집"),
        ("산출물작성", nil), ("문서작성", "산출물작성"), ("발표자료", "산출물작성"), ("코드작성", "산출물작성"),
        ("커뮤니케이션", nil), ("회의", "커뮤니케이션"), ("메신저대응", "커뮤니케이션"),
        ("학습", nil), ("강의수강", "학습"), ("복습", "학습"), ("면접·시험준비", "학습"),
        ("반복작업", nil), ("데이터정리", "반복작업"),
        ("행정처리", nil), ("신청·지원", "행정처리"), ("일정·공지확인", "행정처리"),
        ("기타", nil),
    ]

    /// 업무 종류 목록의 판. 목록을 바꾸면 올린다. 업무를 만들 때 props.type_version 에 남기고, 옛 판 업무는 테마 단계가 종류를 다시 붙인다
    public static let version = 2

    public static let resourceTypes: [(name: String, parent: String?)] = [
        ("참고자료", nil), ("Documentation", "참고자료"), ("QnA", "참고자료"), ("Paper", "참고자료"),
        ("Video", "참고자료"), ("AIChat", "참고자료"), ("WebPage", "참고자료"), ("Recording", "참고자료"),
        ("산출물", nil), ("CodeFile", "산출물"), ("Note", "산출물"), ("Document", "산출물"), ("Design", "산출물"),
        ("Preview", nil), ("Message", nil),
    ]

    public static let fallbackTaskType = "기타"

    /// LLM이 고를 수 있는 업무 종류: 하위 클래스 + 기타.
    public static var leafTaskTypes: [String] {
        let parents = Set(taskTypes.compactMap(\.parent))
        return taskTypes.map(\.name).filter { !parents.contains($0) }
    }

    /// 고를 수 있는 종류 이름으로 맞춘다 (공백·가운뎃점 차이는 무시). 없으면 nil
    public static func leafType(_ name: String) -> String? {
        func key(_ text: String) -> String { text.filter { !$0.isWhitespace && $0 != "·" } }
        let wanted = key(name)
        return leafTaskTypes.first { key($0) == wanted }
    }

    public static func seed(_ tx: GraphTx, at: Double) throws {
        try seed(tx, label: NodeLabel.taskType, types: taskTypes, at: at)
        try seed(tx, label: NodeLabel.resourceType, types: resourceTypes, at: at)
    }

    private static func seed(_ tx: GraphTx, label: String, types: [(name: String, parent: String?)], at: Double) throws {
        var ids: [String: Int64] = [:]
        for type in types {
            ids[type.name] = try tx.upsertNode(label: label, key: type.name, subtype: nil, title: type.name, props: [:], at: at)
        }
        for type in types {
            guard let parent = type.parent, let child = ids[type.name], let parentId = ids[parent] else { continue }
            try tx.upsertEdge(src: child, dst: parentId, type: EdgeType.subclassOf, props: [:], addWeight: 0, at: at, countHit: false)
        }
    }
}
