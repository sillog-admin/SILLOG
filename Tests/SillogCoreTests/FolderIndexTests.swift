import XCTest
@testable import SillogCore

final class FolderIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wg-folders-\(UUID().uuidString)")
        let make: [(String, [String])] = [
            ("Desktop/study/ai 기초수학", ["week1_intro.pdf", "week2_vectors.pdf", "과제1.ipynb"]),
            ("Desktop/study/자료구조 기초 및 활용", ["ch3_linkedlist.pdf"]),
            ("Desktop/study/앱 개발/Sillog", ["Package.swift"]),
            ("Desktop/study/앱 개발/Sillog/Sources", ["main.swift"]),
            ("Desktop/study/앱 개발/Sillog/.build/debug", ["junk"]),
            ("Documents/영수증", ["2026-08.pdf"]),
            ("Documents/node_modules/pkg", ["index.js"]),
            ("Library/Caches/x", ["c"]),
        ]
        for (path, files) in make {
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in files { try Data("x".utf8).write(to: dir.appendingPathComponent(file)) }
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testScanSkipsBuildAndSystemFoldersAndKeepsSamples() {
        let index = FolderIndex.scan(roots: [root.appendingPathComponent("Desktop").path, root.appendingPathComponent("Documents").path],
                                     home: root.path, maxDepth: 4)
        let paths = index.folders.map(\.relativePath)
        XCTAssertTrue(paths.contains("~/Desktop/study/ai 기초수학"))
        XCTAssertTrue(paths.contains("~/Documents/영수증"))
        XCTAssertFalse(paths.contains { $0.contains(".build") })
        XCTAssertFalse(paths.contains { $0.contains("node_modules") })
        XCTAssertTrue(paths.contains("~/Desktop/study/앱 개발/Sillog"), "저장소 자체는 후보")
        XCTAssertFalse(paths.contains("~/Desktop/study/앱 개발/Sillog/Sources"), "저장소 안은 후보가 아니다")
        let math = index.folders.first { $0.relativePath == "~/Desktop/study/ai 기초수학" }!
        XCTAssertEqual(math.fileCount, 3)
        XCTAssertEqual(Set(math.sampleFiles), ["week1_intro.pdf", "week2_vectors.pdf", "과제1.ipynb"])
        XCTAssertTrue(paths.contains("~/Desktop/study"))                       // 중간 폴더도 후보
    }

    func testRankingUsesFileNameContextAndFolderContents() {
        let index = FolderIndex.scan(roots: [root.appendingPathComponent("Desktop").path, root.appendingPathComponent("Documents").path],
                                     home: root.path, maxDepth: 4)
        // 강의자료 다운로드: 파일명엔 폴더 이름과 겹치는 게 없지만, 그때 보던 창 제목에 과목명이 있다
        let ranked = index.rank(fileName: "week3_linear_algebra.pdf", context: ["AI기초수학 3주차 강의자료 - LMS"], limit: 3)
        XCTAssertEqual(ranked.first?.relativePath, "~/Desktop/study/ai 기초수학")
        // 영수증
        let receipts = index.rank(fileName: "2026-09_receipt.pdf", context: ["카드 영수증 조회"], limit: 3)
        XCTAssertEqual(receipts.first?.relativePath, "~/Documents/영수증")
    }

    func testTokenizerNormalizesKoreanAndCaseAndSpacing() {
        XCTAssertEqual(FolderIndex.tokens("AI기초수학 3주차 Week3_linear-algebra.PDF"), ["ai기초수학", "3주차", "week3", "linear", "algebra", "pdf"])
        XCTAssertTrue(FolderIndex.similar("ai 기초수학", "AI기초수학"))       // 공백·대소문자 무시
    }
}
