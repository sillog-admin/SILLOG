import XCTest
@testable import WorkGraphCore

final class FileSuggestionCopyTests: XCTestCase {
    func testBodyMatchesFigmaExample() {
        XCTAssertEqual(FileSuggestionCopy.title, "파일을 정리할까요?")
        XCTAssertEqual(FileSuggestionCopy.body(fileName: "통계학_수업자료.pdf", folder: "/Users/me/Documents/통계학", home: "/Users/me"),
                       "통계학_수업자료.pdf\n→ 문서 › 통계학")
    }

    func testParticleFollowsLastHangulSyllable() {
        XCTAssertEqual(FileSuggestionCopy.objectParticle("보고서"), "를")
        XCTAssertEqual(FileSuggestionCopy.objectParticle("논문"), "을")
        XCTAssertEqual(FileSuggestionCopy.objectParticle("report.pdf"), "을")
        XCTAssertEqual(FileSuggestionCopy.objectParticle(""), "을")
    }

    func testFolderLabel() {
        let home = "/Users/me"
        XCTAssertEqual(FileSuggestionCopy.folderLabel("/Users/me/Downloads", home: home), "다운로드")
        XCTAssertEqual(FileSuggestionCopy.folderLabel("/Users/me/Documents/통계학/", home: home), "문서 / 통계학")
        XCTAssertEqual(FileSuggestionCopy.folderLabel("/Users/me/프로젝트/기획", home: home), "프로젝트 / 기획")
        XCTAssertEqual(FileSuggestionCopy.folderLabel("/Users/me", home: home), "홈")
        XCTAssertEqual(FileSuggestionCopy.folderLabel("/Volumes/USB/자료", home: home), "Volumes / USB / 자료")
        XCTAssertEqual(FileSuggestionCopy.folderLabel("/Users/meow/a", home: home), "Users / meow / a", "이름만 홈으로 시작하는 다른 폴더")
    }

    func testRecordingNotificationCopy() {
        let home = "/Users/me"
        XCTAssertEqual(FileSuggestionCopy.recordingTitle, "받아쓴 녹음을 정리할까요?")
        XCTAssertEqual(FileSuggestionCopy.recordingBody(fileName: "2026-10-10 자료구조 3주차 강의.md", folder: "/Users/me/Documents/학교/자료구조", home: home),
                       "2026-10-10 자료구조 3주차 강의.md\n→ 문서 › 학교 › 자료구조")
        XCTAssertEqual(FileSuggestionCopy.transcribedTitle, "녹음을 받아썼어요")
        XCTAssertEqual(FileSuggestionCopy.transcribedBody(fileName: "2026-10-10 회의.md", folder: "/Users/me/Documents/SILLOG 녹음", home: home),
                       "'2026-10-10 회의.md'를 문서 / SILLOG 녹음 폴더에 저장했어요.")
    }
}
