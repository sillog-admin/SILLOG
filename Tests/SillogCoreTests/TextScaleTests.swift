import XCTest
@testable import SillogCore

final class TextScaleTests: XCTestCase {
    func testStepsAndStopsAtTheEnds() {
        XCTAssertEqual(TextScale.step(1.0, by: 1), 1.15)
        XCTAssertEqual(TextScale.step(1.0, by: -1), 0.85)
        XCTAssertEqual(TextScale.step(1.5, by: 1), 1.5)
        XCTAssertEqual(TextScale.step(0.85, by: -1), 0.85)
    }

    func testOffStepValueMovesToTheNeighbouringStep() {
        XCTAssertEqual(TextScale.step(1.2, by: 1), 1.3)
        XCTAssertEqual(TextScale.step(1.2, by: -1), 1.15)
    }

    func testClamp() {
        XCTAssertEqual(TextScale.clamp(3), 1.5)
        XCTAssertEqual(TextScale.clamp(0.2), 0.85)
        XCTAssertEqual(TextScale.clamp(1.15), 1.15)
    }
}
