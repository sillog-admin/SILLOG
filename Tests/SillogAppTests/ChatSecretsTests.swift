import XCTest
@testable import SillogApp

/// Accounts known to be empty load without touching the Keychain item.
final class ChatSecretsTests: XCTestCase {
    private var suite = ""

    override func setUp() {
        suite = "sillog.tests.secrets.\(UUID().uuidString)"
        ChatSecrets.memoryOnly = true
        ChatSecrets.defaults = UserDefaults(suiteName: suite)
        ChatSecrets.resetForTests()
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        ChatSecrets.defaults = .standard
        ChatSecrets.memoryOnly = false
        ChatSecrets.resetForTests()
    }

    func testTheListHoldsOnlyAccountsWithASecret() throws {
        try ChatSecrets.save("sk-test", account: "settings.llm")
        XCTAssertEqual(ChatSecrets.defaults?.stringArray(forKey: "sillog.chat.secretAccounts"), ["settings.llm"])
        XCTAssertEqual(try ChatSecrets.load("settings.jev"), "")
        XCTAssertEqual(try ChatSecrets.load("settings.llm"), "sk-test")

        try ChatSecrets.save("", account: "settings.llm")
        XCTAssertEqual(ChatSecrets.defaults?.stringArray(forKey: "sillog.chat.secretAccounts"), [])
        XCTAssertEqual(try ChatSecrets.load("settings.llm"), "")
    }

    func testAnUnlistedAccountSkipsTheStoredItem() throws {
        try ChatSecrets.save("sk-test", account: "settings.llm")
        ChatSecrets.defaults?.set([String](), forKey: "sillog.chat.secretAccounts")
        XCTAssertEqual(try ChatSecrets.load("settings.llm"), "")    // the list, not the item, decides
    }

    func testTheFirstLoadWritesTheList() throws {
        XCTAssertNil(ChatSecrets.defaults?.stringArray(forKey: "sillog.chat.secretAccounts"))
        XCTAssertEqual(try ChatSecrets.load("settings.llm"), "")
        XCTAssertEqual(ChatSecrets.defaults?.stringArray(forKey: "sillog.chat.secretAccounts"), [])
    }
}
