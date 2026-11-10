import XCTest
import GRDB
@testable import WorkGraphCore

final class RelationSchemaTests: XCTestCase {
    func testEveryEdgeTypeHasARuleWithKnownLabels() {
        let all = [EdgeType.partOf, EdgeType.instanceOf, EdgeType.subclassOf, EdgeType.used, EdgeType.touched, EdgeType.about,
                   EdgeType.belongsTo, EdgeType.on, EdgeType.hit, EdgeType.resolvedBy, EdgeType.switchedTo, EdgeType.forTask,
                   EdgeType.createdDuring, EdgeType.derivedFrom]
        XCTAssertEqual(Set(RelationSchema.rules.map(\.type)), Set(all))
        let labels = Set(ClassSchema.classes.map(\.label))
        for rule in RelationSchema.rules {
            XCTAssertTrue(rule.from.isSubset(of: labels), "\(rule.type) 출발 클래스가 정의에 없음: \(rule.from)")
            XCTAssertTrue(rule.to.isSubset(of: labels), "\(rule.type) 도착 클래스가 정의에 없음: \(rule.to)")
            XCTAssertFalse(rule.meaning.isEmpty)
        }
    }

    func testDomainAndRangeChecks() {
        XCTAssertTrue(RelationSchema.allows(type: "PART_OF", from: "Session", to: "Task"))
        XCTAssertFalse(RelationSchema.allows(type: "PART_OF", from: "Task", to: "Session"))
        XCTAssertTrue(RelationSchema.allows(type: "INSTANCE_OF", from: "Resource", to: "ResourceType"))
        XCTAssertFalse(RelationSchema.allows(type: "INSTANCE_OF", from: "Resource", to: "TaskType"))
        XCTAssertTrue(RelationSchema.allows(type: "ABOUT", from: "Resource", to: "Topic"))
        XCTAssertFalse(RelationSchema.allows(type: "LIKES", from: "Task", to: "Topic"))
    }

    func testStorageRejectsEdgesThatBreakTheSchema() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: "Task", key: "t", subtype: nil, title: "t", props: [:], at: 1)
            let session = try tx.upsertNode(label: "Session", key: "s", subtype: nil, title: "s", props: [:], at: 1)
            let topic = try tx.upsertNode(label: "Topic", key: "x", subtype: nil, title: "x", props: [:], at: 1)
            try tx.upsertEdge(src: session, dst: task, type: "PART_OF", props: [:], addWeight: 0, at: 1)

            XCTAssertThrowsError(try tx.upsertEdge(src: task, dst: session, type: "PART_OF", props: [:], addWeight: 0, at: 1)) { error in
                guard case OntologyError.invalidRelation(let type, let from, let to) = error else { return XCTFail("\(error)") }
                XCTAssertEqual([type, from, to], ["PART_OF", "Task", "Session"])
                XCTAssertTrue("\(error)".contains("Session → Task"), "에러 메시지에 허용되는 방향이 나와야 함: \(error)")
            }
            XCTAssertThrowsError(try tx.upsertEdge(src: task, dst: topic, type: "LIKES", props: [:], addWeight: 0, at: 1)) { error in
                guard case OntologyError.unknownRelation("LIKES") = error else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try tx.upsertEdge(src: task, dst: 9_999, type: "ABOUT", props: [:], addWeight: 0, at: 1))
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges"), 1)
        }
    }
}
