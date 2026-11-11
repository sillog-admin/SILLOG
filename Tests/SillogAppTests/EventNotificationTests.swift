import UserNotifications
import XCTest
@testable import SillogApp

final class EventNotificationTests: XCTestCase {
    func testAnnouncesOnlySuggestionsMadeAfterFirstLook() {
        var announcer = EventAnnouncer()
        XCTAssertEqual(announcer.fresh(ids: [1, 2]), [], "앱을 켤 때 이미 있던 제안은 알리지 않는다")
        XCTAssertEqual(announcer.fresh(ids: [1, 2, 3]), [3])
        XCTAssertEqual(announcer.fresh(ids: [2, 3, 5, 4]), [5, 4], "새 제안은 받은 순서(가까운 날짜부터) 그대로")
        XCTAssertEqual(announcer.fresh(ids: [4, 5]), [])
    }

    /// 등록·무시했거나 날짜가 지나 제안에 없는 일정의 알림은 지운다 (파일 정리 알림은 그대로)
    func testPicksDeliveredEventNotificationsThatAreNoLongerSuggested() {
        let delivered = ["event-suggestion-1", "event-suggestion-2", "file-suggestion-1", "recording-abc"]
        XCTAssertEqual(SuggestionNotifier.staleEventIdentifiers(delivered, keeping: [2]), ["event-suggestion-1"])
        XCTAssertEqual(SuggestionNotifier.staleEventIdentifiers(delivered, keeping: [1, 2]), [])
    }

    func testRoutesEventAndFileNotificationButtons() {
        XCTAssertEqual(SuggestionNotifier.route(userInfo: ["eventSuggestionId": NSNumber(value: 7)], action: "register"), .event(.register, 7))
        XCTAssertEqual(SuggestionNotifier.route(userInfo: ["eventSuggestionId": Int64(7)], action: "ignore"), .event(.ignore, 7))
        XCTAssertEqual(SuggestionNotifier.route(userInfo: ["eventSuggestionId": Int64(7)], action: UNNotificationDefaultActionIdentifier), .event(.open, 7))
        XCTAssertEqual(SuggestionNotifier.route(userInfo: ["suggestionId": Int64(3)], action: "move"), .file(.move, 3))
        XCTAssertEqual(SuggestionNotifier.route(userInfo: ["suggestionId": NSNumber(value: 3)], action: "ignore"), .file(.ignore, 3))
        XCTAssertNil(SuggestionNotifier.route(userInfo: [:], action: "move"))
    }
}
