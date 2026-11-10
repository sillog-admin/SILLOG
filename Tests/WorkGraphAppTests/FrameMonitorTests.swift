import XCTest
@testable import WorkGraphApp

/// 개발용 프레임 측정기: 화면 갱신 사이 간격이 한 프레임의 1.5배를 넘으면 늦음, 3배를 넘으면 많이 늦음 (120Hz 면 12.5ms, 25ms)
final class FrameMonitorTests: XCTestCase {
    func testAGapIsOnTimeLateOrVeryLate() {
        let frame = 1.0 / 120
        XCTAssertEqual(FrameMonitor.lateness(gap: frame, interval: frame), .onTime)
        XCTAssertEqual(FrameMonitor.lateness(gap: frame * 1.4, interval: frame), .onTime)
        XCTAssertEqual(FrameMonitor.lateness(gap: frame * 2, interval: frame), .late, "한 장을 놓침")
        XCTAssertEqual(FrameMonitor.lateness(gap: frame * 4, interval: frame), .veryLate, "눈에 띄게 멈칫")
    }
}
