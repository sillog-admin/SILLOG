import XCTest
@testable import WorkGraphCore

final class RuleClassifierTests: XCTestCase {
    private func classify(bundle: String = "com.google.Chrome", app: String = "Google Chrome", title: String? = nil,
                          url: String? = nil, doc: String? = nil, existing: Set<String> = []) -> ClassifiedResource? {
        RuleClassifier.classify(appBundle: bundle, appName: app, windowTitle: title, url: url, docPath: doc,
                                home: "/Users/me", fileExists: { existing.contains($0) })
    }

    func testWebSubtypes() {
        XCTAssertEqual(classify(url: "https://ui.shadcn.com/docs/components/card")?.subtype, "Documentation")
        XCTAssertEqual(classify(url: "https://stackoverflow.com/questions/28329382/react-key-prop")?.subtype, "QnA")
        XCTAssertEqual(classify(url: "https://github.com/facebook/react/issues/123")?.subtype, "QnA")
        XCTAssertEqual(classify(url: "http://localhost:3000/")?.subtype, "Preview")
        XCTAssertEqual(classify(url: "https://arxiv.org/abs/2401.05566")?.subtype, "Paper")
        XCTAssertEqual(classify(url: "https://www.youtube.com/watch?v=abc")?.subtype, "Video")
        XCTAssertEqual(classify(url: "https://chatgpt.com/c/123")?.subtype, "AIChat")
        XCTAssertEqual(classify(url: "https://claude.ai/chat/abc")?.subtype, "AIChat")
        XCTAssertEqual(classify(url: "https://docs.google.com/document/d/1/edit")?.subtype, "Document")
        XCTAssertEqual(classify(url: "https://www.figma.com/design/abc/Dashboard")?.subtype, "Design")
        XCTAssertEqual(classify(url: "https://news.ycombinator.com/item?id=1")?.subtype, "WebPage")
    }

    func testWebKeyIsNormalizedAndTitleDropsBrowserSuffix() {
        let r = classify(title: "Card - shadcn/ui - Google Chrome", url: "https://ui.shadcn.com/docs/components/card?utm_source=x#usage")
        XCTAssertEqual(r?.key, "https://ui.shadcn.com/docs/components/card")
        XCTAssertEqual(r?.title, "Card - shadcn/ui")
    }

    func testCodeFileWithProjectRoot() {
        let r = classify(bundle: "com.apple.dt.Xcode", app: "Xcode", title: "dashboard — TaskCard.tsx",
                         doc: "file:///Users/me/proj/dashboard/src/components/TaskCard.tsx",
                         existing: ["/Users/me/proj/dashboard/package.json"])
        XCTAssertEqual(r?.subtype, "CodeFile")
        XCTAssertEqual(r?.key, "file:~/proj/dashboard/src/components/TaskCard.tsx")
        XCTAssertEqual(r?.title, "TaskCard.tsx")
        XCTAssertEqual(r?.projectKey, "file:~/proj/dashboard")
        XCTAssertEqual(r?.projectTitle, "dashboard")
    }

    func testEditorWindowTitleWithoutDocPath() {
        let r = classify(bundle: "com.todesktop.230313mzl4w4u92", app: "Cursor", title: "● TaskCard.tsx — dashboard")
        XCTAssertEqual(r?.subtype, "CodeFile")
        XCTAssertEqual(r?.key, "code:dashboard/TaskCard.tsx")
        XCTAssertEqual(r?.title, "TaskCard.tsx")
        XCTAssertEqual(r?.projectKey, "project:dashboard")
        XCTAssertEqual(r?.projectTitle, "dashboard")
    }

    func testDocumentsAndNotes() {
        XCTAssertEqual(classify(bundle: "com.hancom.office.hwp", app: "한글", doc: "/Users/me/Documents/지원서.hwp")?.subtype, "Document")
        XCTAssertEqual(classify(bundle: "com.microsoft.Word", app: "Word", doc: "/Users/me/Documents/보고서.docx")?.subtype, "Document")
        XCTAssertEqual(classify(bundle: "md.obsidian", app: "Obsidian", doc: "/Users/me/vault/논문정리.md")?.subtype, "Note")
    }

    func testDownloadedArxivPdfSharesKeyWithWebPage() {
        let pdf = classify(bundle: "com.apple.Preview", app: "Preview", doc: "/Users/me/Downloads/2401.05566v2.pdf")
        XCTAssertEqual(pdf?.key, "arxiv:2401.05566")
        XCTAssertEqual(pdf?.subtype, "Paper")
        XCTAssertEqual(pdf?.key, classify(url: "https://arxiv.org/abs/2401.05566")?.key)
    }

    func testAppWithoutUrlOrDocHasNoResource() {
        XCTAssertNil(classify(bundle: "com.tinyspeck.slackmacgap", app: "Slack", title: "디자인팀 - Slack"))
        XCTAssertNil(classify(bundle: "com.apple.Terminal", app: "Terminal", title: "npm run dev"))
    }
}
