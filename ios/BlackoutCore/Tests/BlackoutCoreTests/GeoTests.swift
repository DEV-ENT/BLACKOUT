import XCTest
@testable import BlackoutCore

final class GeoTests: XCTestCase {
    let duomo = Spot(lat: 45.46420, lon: 9.19000, accuracy: 12)

    func testCheckInCarriesPosition() {
        let t = CheckIn.safe.text(battery: 23, spot: duomo)
        XCTAssertEqual(t, "✅ I'm safe · 🔋 23% · 📍 45.46420,9.19000 ±12m")
        XCTAssertEqual(CheckIn.of(t), .safe)
        XCTAssertEqual(CheckIn.battery(in: t), 23)
        XCTAssertEqual(CheckIn.spot(in: t), duomo)
        let noBattery = CheckIn.help.text(battery: nil, spot: Spot(lat: -33.8688, lon: 151.2093))
        XCTAssertEqual(noBattery, "🆘 I need help · 📍 -33.86880,151.20930")
        XCTAssertEqual(CheckIn.spot(in: noBattery), Spot(lat: -33.8688, lon: 151.2093))
        XCTAssertEqual(CheckIn.safe.text(battery: nil, spot: nil), CheckIn.safe.rawValue)
    }

    func testBadPositionsAreIgnored() {
        XCTAssertNil(CheckIn.spot(in: CheckIn.safe.rawValue))
        XCTAssertNil(CheckIn.spot(in: "Meet at 📍 45.46420,9.19000"))            // not a check-in
        XCTAssertNil(CheckIn.spot(in: "✅ I'm safe · 📍 91.00000,9.19000"))      // latitude out of range
        XCTAssertNil(CheckIn.spot(in: "✅ I'm safe · 📍 45.4,181.0"))
        XCTAssertNil(CheckIn.spot(in: "✅ I'm safe · 📍 near the school"))
        XCTAssertNil(CheckIn.spot(in: "✅ I'm safe · 📍 45.46420;9.19000"))
        XCTAssertNil(CheckIn.spot(in: "✅ I'm safe · 📍 1e2,9"))
        XCTAssertEqual(CheckIn.spot(in: "✅ I'm safe · 📍 45.46420,9.19000 ±lots"), Spot(lat: 45.4642, lon: 9.19)) // bad accuracy: dropped
        XCTAssertEqual(CheckIn.safe.text(battery: nil, spot: Spot(lat: 95, lon: 0)), CheckIn.safe.rawValue)       // invalid: not sent
    }

    func testDistanceAndBearing() {
        let equator = Spot(lat: 0, lon: 0)
        XCTAssertEqual(Geo.distance(equator, Spot(lat: 1, lon: 0)), 111_195.08, accuracy: 0.05)
        XCTAssertEqual(Geo.bearing(equator, Spot(lat: 1, lon: 0)), 0, accuracy: 0.001)
        XCTAssertEqual(Geo.bearing(equator, Spot(lat: 0, lon: 1)), 90, accuracy: 0.001)
        XCTAssertEqual(Geo.bearing(equator, Spot(lat: -1, lon: 0)), 180, accuracy: 0.001)
        XCTAssertEqual(Geo.bearing(equator, Spot(lat: 0, lon: -1)), 270, accuracy: 0.001)
        // Values cross-checked in Python.
        let marco = Spot(lat: 45.46600, lon: 9.19200)
        XCTAssertEqual(Geo.distance(duomo, marco), 253.75, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(duomo, marco), 37.93, accuracy: 0.01)
        XCTAssertEqual(Geo.distance(duomo, duomo), 0)
        XCTAssertEqual(Geo.compassWord(37.93), "Northeast")
        XCTAssertEqual(Geo.compassWord(359), "North")
        XCTAssertEqual(Geo.compassWord(-90), "West")
    }

    func testPersonKeepsLastKnownPosition() {
        func m(_ ts: Int64, _ text: String) -> Message { Message(id: "a\(ts)", ts: ts, sender: "a", name: "Ann", text: text) }
        let p = Person.all(in: [
            m(100, CheckIn.safe.text(battery: 50, spot: duomo)),
            m(200, CheckIn.safe.text(battery: 40)),   // no position this time: the last known one stays, with its time
        ], me: "me").first
        XCTAssertEqual(p?.spot, duomo)
        XCTAssertEqual(p?.spotTs, 100)
        XCTAssertEqual(p?.battery, 40)
    }
}
