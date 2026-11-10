import XCTest
@testable import WorkGraphApp

/// 메뉴 막대 아이콘 첫 자리: 저장된 자리가 없으면 시계 쪽(노치에서 먼 쪽)에, 사용자가 옮긴 자리가 있으면 그대로
final class MenuBarPlacementTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "wg-menubar-placement-\(UUID().uuidString)"

    override func setUp() { defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testWithoutASavedPositionTheIconStartsNearTheClock() {
        MenuBarPlacement.preferRightSide(defaults)
        XCTAssertEqual(defaults.double(forKey: MenuBarPlacement.key), MenuBarPlacement.rightSide)
    }

    func testAPositionTheUserChoseIsKept() {
        defaults.set(448.0, forKey: MenuBarPlacement.key)
        MenuBarPlacement.preferRightSide(defaults)
        XCTAssertEqual(defaults.double(forKey: MenuBarPlacement.key), 448)
    }
}
