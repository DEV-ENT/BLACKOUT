import XCTest
@testable import BlackoutCore

/// The same strings as Android's ProtocolTest.statusShareText.
final class StatusShareTests: XCTestCase {
    func testText() {
        let t = StatusShare.text(.help, name: "Anna", battery: 64, spot: Spot(lat: 45.46420, lon: 9.19000, accuracy: 12))
        XCTAssertEqual(t, "🆘 I need help — Anna. Battery 64%. 45.46420, 9.19000 ±12 m https://osm.org/?mlat=45.46420&mlon=9.19000")
        XCTAssertLessThanOrEqual(t.count, 160)
        XCTAssertEqual(StatusShare.text(.safe, name: " ", battery: nil, spot: nil), "✅ I'm safe.")
        XCTAssertEqual(StatusShare.text(.safe, name: "Ben", battery: 101, spot: Spot(lat: -33.8688, lon: 151.2093)),
                       "✅ I'm safe — Ben. -33.86880, 151.20930 https://osm.org/?mlat=-33.86880&mlon=151.20930")
        let long = StatusShare.text(.help, name: String(repeating: "x", count: 60), battery: 100,
                                    spot: Spot(lat: -89.99999, lon: -179.99999, accuracy: 99_999))
        XCTAssertLessThanOrEqual(long.count, 160)
    }
}
