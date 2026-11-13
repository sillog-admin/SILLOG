import XCTest
@testable import SillogCore

final class DrivePickerTests: XCTestCase {
    func testPageUsesProjectNumberAndEscapesValues() {
        let page = DrivePicker.page(token: "tok</script>", apiKey: "key", clientID: "123456-abc.apps.googleusercontent.com", state: "s1")
        XCTAssertTrue(page.contains(#"setAppId("123456")"#))
        XCTAssertTrue(page.contains(#""tok<\/script>""#), "token cannot close the script tag")
        XCTAssertFalse(page.contains("tok</script>"))
        XCTAssertTrue(page.contains(#""/drive-picked?state=s1&count=""#))
    }
}
