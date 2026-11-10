import XCTest
@testable import WorkGraphCore

final class TopicFilterTests: XCTestCase {
    func testPlatformsAppsProjectsAndFillerAreDropped() {
        let cleaned = TopicFilter.clean(["온톨로지", "GitHub", "Discord", "DBeaver", "기타", "WorkGraph", "그래프 DB", "Claude Code", "LMS", "VS Code", "선형대수"],
                                        apps: ["DBeaver", "Code", "Google Chrome"], projects: ["WorkGraph"])
        XCTAssertEqual(cleaned, ["온톨로지", "그래프 DB", "선형대수"])
    }

    func testTechnologiesAndSubjectsStay() {
        let cleaned = TopicFilter.clean(["Swift", "Git", "GRDB", "React 상태 관리", "장치 코드 인증", "OpenAI API", "Jev"], apps: ["Code"], projects: [])
        XCTAssertEqual(cleaned, ["Swift", "Git", "GRDB", "React 상태 관리", "장치 코드 인증", "OpenAI API", "Jev"])
    }

    func testLooseMatchingAndDedupe() {
        XCTAssertEqual(TopicFilter.rejection("vscode", apps: [], projects: []), "플랫폼·서비스")
        XCTAssertEqual(TopicFilter.rejection("Kakao Talk", apps: ["카카오톡"], projects: []), "플랫폼·서비스")
        XCTAssertEqual(TopicFilter.rejection("Screenpipe", apps: [], projects: ["screenpipe"]), "프로젝트 이름")
        XCTAssertEqual(TopicFilter.rejection("Google Chrome.app", apps: ["Google Chrome"], projects: []), "플랫폼·서비스")
        XCTAssertNil(TopicFilter.rejection("온톨로지", apps: [], projects: []))
        XCTAssertEqual(TopicFilter.rejection("lab.ipynb", apps: [], projects: []), "파일 이름")
        XCTAssertEqual(TopicFilter.rejection("report_final.pdf", apps: [], projects: []), "파일 이름")
        XCTAssertNil(TopicFilter.rejection("Node.js", apps: [], projects: []))
        XCTAssertNil(TopicFilter.rejection("ASP.NET", apps: [], projects: []))
        XCTAssertEqual(TopicFilter.clean(["온톨로지", "온톨로지 ", "Ontology", "#온톨로지"], apps: [], projects: []), ["온톨로지", "Ontology"])
    }
}
