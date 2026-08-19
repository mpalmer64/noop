import XCTest
@testable import WhoopStore

/// The REFUSALS matter more than the composition: adoption migrates every device-scoped row onto the id
/// this returns, so a junk serial must yield nil and leave the strap on its existing id rather than move a
/// history onto a garbage key (#1303). Kotlin twin: `WhoopSerialIdentityTest`.
final class WhoopSerialIdentityTests: XCTestCase {

    func testComposesTheSerialId() {
        XCTAssertEqual(WhoopSerialIdentity.adoptedId(serial: "5AG12345678"), "whoop-5AG12345678")
    }

    func testUpperCasesSoOneStrapCannotBecomeTwoIds() {
        XCTAssertEqual(WhoopSerialIdentity.adoptedId(serial: "5ag12345678"),
                       WhoopSerialIdentity.adoptedId(serial: "5AG12345678"))
    }

    func testTrimsSurroundingWhitespaceFromTheGattString() {
        XCTAssertEqual(WhoopSerialIdentity.adoptedId(serial: "  5AG12345678\n"), "whoop-5AG12345678")
    }

    func testRefusesBlankOrMissing() {
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: nil))
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: ""))
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: "   \n "))
    }

    func testRefusesATruncatedRead() {
        // A partial GATT response must not become an id: it would collide across straps.
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: "5AG"))
    }

    func testRefusesADescriptiveStringThatIsNotASerial() {
        // Some peripherals answer DIS with prose. Never let that become a device id.
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: "Not Available"))
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: "serial#1234"))
    }

    func testAlreadyAdoptedIsTheReconnectEarlyOut() {
        XCTAssertTrue(WhoopSerialIdentity.isAlreadyAdopted(id: "whoop-5AG12345678", serial: "5AG12345678"))
        XCTAssertFalse(WhoopSerialIdentity.isAlreadyAdopted(id: "whoop-ABCDEF-0123", serial: "5AG12345678"))
        // An unusable serial is never "already adopted" — otherwise a junk read would silently suppress a
        // later good one.
        XCTAssertFalse(WhoopSerialIdentity.isAlreadyAdopted(id: "whoop-5AG12345678", serial: "  "))
    }

    func testLogSafeNeverLeaksTheFullSerial() {
        XCTAssertEqual(WhoopSerialIdentity.logSafe(serial: "5AG12345678"), "5AG…")
        XCTAssertEqual(WhoopSerialIdentity.logSafe(serial: nil), "?")
        XCTAssertFalse(WhoopSerialIdentity.logSafe(serial: "5AG12345678").contains("12345678"))
    }
}
