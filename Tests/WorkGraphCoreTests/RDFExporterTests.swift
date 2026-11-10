import XCTest
import GRDB
@testable import WorkGraphCore

final class RDFExporterTests: XCTestCase {
    /// 프론트 개발 시나리오를 그래프에 넣고 그대로 내보낸다.
    private func exportFrontend() throws -> String {
        let db = try WGDatabase.inMemory()
        return try db.writer.write { conn -> String in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            _ = try AssignmentApplier().apply(try Fixtures.patch(Fixtures.frontendPatchJSON), rows: Fixtures.frontendRows(), tx: tx, now: 2_000_000)
            return RDFExporter.export(try tx.subgraph(since: nil, includeTBox: true))
        }
    }

    func testVocabularyMapsOurClassesOntoStandardOnes() {
        let turtle = RDFExporter.vocabulary()
        XCTAssertTrue(turtle.contains("@prefix prov: <http://www.w3.org/ns/prov#> ."))
        XCTAssertTrue(turtle.contains("wg:Session a rdfs:Class ;\n    rdfs:subClassOf prov:Activity"))
        XCTAssertTrue(turtle.contains("wg:Resource a rdfs:Class ;\n    rdfs:subClassOf prov:Entity"))
        XCTAssertTrue(turtle.contains("wg:App a rdfs:Class ;\n    rdfs:subClassOf prov:SoftwareAgent"))
        XCTAssertTrue(turtle.contains("wg:Topic a rdfs:Class ;\n    rdfs:subClassOf skos:Concept"))
        XCTAssertTrue(turtle.contains("wg:resolvedBy a rdf:Property ;\n    rdfs:domain wg:Problem ;\n    rdfs:range wg:Resource ;\n    rdfs:subPropertyOf prov:wasInfluencedBy"))
        XCTAssertTrue(turtle.contains("wg:switchedTo a rdf:Property ;\n    rdfs:domain wg:Session ;\n    rdfs:range wg:Session"))
    }

    func testInstancesUseProvPatterns() throws {
        let turtle = try exportFrontend()
        // 클래스 층: 하위 종류는 상위 종류의 subClassOf, 최상위는 wg:Task / wg:Resource 의 subClassOf
        XCTAssertTrue(turtle.contains("wg:TaskType_코드작성 a rdfs:Class ;\n    rdfs:label \"코드작성\" ;\n    rdfs:subClassOf wg:TaskType_산출물작성"))
        XCTAssertTrue(turtle.contains("wg:TaskType_산출물작성 a rdfs:Class ;\n    rdfs:label \"산출물작성\" ;\n    rdfs:subClassOf wg:Task"))
        XCTAssertTrue(turtle.contains("wg:ResourceType_QnA a rdfs:Class ;\n    rdfs:label \"QnA\" ;\n    rdfs:subClassOf wg:ResourceType_참고자료"))
        // 인스턴스: 업무는 자기 종류의 인스턴스이자 prov:Activity
        XCTAssertTrue(turtle.contains("a wg:Task, prov:Activity, wg:TaskType_코드작성 ;"))
        XCTAssertTrue(turtle.contains("rdfs:label \"대시보드 카드 UI 구현\""))
        // 세션: 시간과 소속
        XCTAssertTrue(turtle.contains("prov:startedAtTime \"1970-01-12T13:46:40Z\"^^xsd:dateTime"))
        XCTAssertTrue(turtle.contains("dcterms:isPartOf wgi:n"))
        // 자료를 봤다 = prov:used + 체류시간이 붙은 qualified usage
        XCTAssertTrue(turtle.contains("prov:used wgi:n"))
        XCTAssertTrue(turtle.contains("prov:qualifiedUsage [ a prov:Usage ; prov:entity wgi:n"))
        XCTAssertTrue(turtle.contains("wg:dwellSeconds 780 ]"))
        // 앱 = 소프트웨어 에이전트와 연관
        XCTAssertTrue(turtle.contains("prov:wasAssociatedWith wgi:n"))
        // 문제는 세션에서 생겼고 자료로 해결됐다
        XCTAssertTrue(turtle.contains("prov:wasGeneratedBy wgi:n"))
        XCTAssertTrue(turtle.contains("wg:resolvedBy wgi:n"))
        // 주제
        XCTAssertTrue(turtle.contains("dcterms:subject wgi:n"))
        XCTAssertTrue(turtle.contains("a wg:Topic, skos:Concept ;"))
    }

    func testLiteralsAreEscapedAndClassNamesSanitized() {
        XCTAssertEqual(RDFExporter.literal("say \"hi\"\nnew\\line"), "\"say \\\"hi\\\"\\nnew\\\\line\"")
        XCTAssertEqual(RDFExporter.classIRI(label: "ResourceType", key: "shadcn/ui docs"), "wg:ResourceType_shadcn_ui_docs")
        XCTAssertEqual(RDFExporter.classIRI(label: "TaskType", key: "코드작성"), "wg:TaskType_코드작성")
    }

    func testEveryStatementEndsWithADotAndNothingIsLeftOpen() throws {
        let turtle = try exportFrontend()
        XCTAssertEqual(turtle.filter { $0 == "[" }.count, turtle.filter { $0 == "]" }.count)
        XCTAssertEqual(turtle.filter { $0 == "\"" }.count % 2, 0)
        for line in turtle.split(separator: "\n") where !line.hasPrefix("@prefix") && !line.hasPrefix("#") && !line.isEmpty {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(trimmed.hasSuffix(".") || trimmed.hasSuffix(";") || trimmed.hasSuffix(",") || trimmed.hasSuffix("]"),
                          "문장이 끝나지 않음: \(line)")
        }
    }
}
