import XCTest
@testable import SillogCore

final class SkillPinTests: XCTestCase {
    func testPinsPersistIndependentlyOfSelectedSkillsAndAllowEmpty() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite").path
        let db = try SillogDatabase(path: path), store = ChatStore(db)
        let defaults = try store.skills()
        XCTAssertEqual(try store.pinnedSkillIDs(), Array(defaults.prefix(6).map(\.id)))
        let custom = try store.addSkill(title: "테스트", instructions: "사용자가 고를 때만 실행")
        var conversation = ChatConversation()
        conversation.skillIDs = [defaults[0].id]
        try store.save(conversation)
        try store.setPinnedSkills([custom.id, defaults[1].id])
        let reloaded = ChatStore(try SillogDatabase(path: path))
        XCTAssertEqual(try reloaded.pinnedSkillIDs(), [custom.id, defaults[1].id])
        XCTAssertEqual(try reloaded.conversations().first?.skillIDs, conversation.skillIDs)
        try reloaded.setPinnedSkills([])
        XCTAssertEqual(try ChatStore(SillogDatabase(path: path)).pinnedSkillIDs(), [])
    }

    func testInvalidPinsDoNotReplaceSavedSelection() throws {
        let store = ChatStore(try SillogDatabase.inMemory())
        let initial = try store.pinnedSkillIDs()
        let extra = try store.addSkill(title: "추가", instructions: "추가 지침")
        XCTAssertThrowsError(try store.setPinnedSkills(initial + [extra.id]))
        XCTAssertThrowsError(try store.setPinnedSkills([initial[0], initial[0]]))
        XCTAssertThrowsError(try store.setPinnedSkills(["missing"]))
        XCTAssertEqual(try store.pinnedSkillIDs(), initial)
    }

    func testDeletingPinnedSkillsRemovesPinsAndEditingKeepsThem() throws {
        let store = ChatStore(try SillogDatabase.inMemory())
        let builtIn = try XCTUnwrap(store.skills().first)
        let added = try store.addSkill(title: "추가", instructions: "추가 지침")
        try store.setPinnedSkills([builtIn.id, added.id])
        _ = try store.updateSkill(added, title: "바뀐 제목", instructions: "바뀐 지침", summary: "")
        XCTAssertEqual(try store.pinnedSkillIDs(), [builtIn.id, added.id])
        try store.deleteSkill(builtIn)
        try store.deleteSkill(added)
        XCTAssertEqual(try store.pinnedSkillIDs(), [])
    }
}
