import XCTest
@testable import BlackoutCore

final class PlacesTests: XCTestCase {
    let gym = Spot(lat: 45.46420, lon: 9.19000, accuracy: 12)

    func testRoundTrip() {
        let p = Place(kind: .water, note: "Tap at the school gym, bring bottles", spot: gym)
        XCTAssertEqual(p.text, "💧 Water: Tap at the school gym, bring bottles · 📍 45.46420,9.19000 ±12m")
        XCTAssertEqual(Place.of(p.text), p)
        for kind in PlaceKind.allCases {
            let q = Place(kind: kind, note: "", spot: nil)
            XCTAssertEqual(Place.of(q.text), q)
        }
        XCTAssertEqual(PlaceKind.medical.word, "Medical")
    }

    func testWithoutPositionOrNote() {
        XCTAssertEqual(Place.of("🔌 Charging: generator at the church"), Place(kind: .charging, note: "generator at the church", spot: nil))
        XCTAssertEqual(Place.of("🏠 Shelter · 📍 45.46420,9.19000"), Place(kind: .shelter, note: "", spot: Spot(lat: 45.4642, lon: 9.19)))
        XCTAssertEqual(Place(kind: .medical, note: "   ", spot: nil).text, "🏥 Medical")
    }

    func testNotPlaces() {
        XCTAssertNil(Place.of("Water at Via Roma 12"))
        XCTAssertNil(Place.of("💧 Waterfall nearby"))
        XCTAssertNil(Place.of(CheckIn.safe.rawValue))
        XCTAssertNil(Place.of(""))
    }

    func testNoteIsCappedAndBadPositionStaysInNote() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(Place.of(Place(kind: .water, note: long, spot: nil).text)?.note.count, Place.maxNote)
        // A malformed position is not a position: it stays part of the note.
        XCTAssertEqual(Place.of("💧 Water: here · 📍 somewhere")?.spot, nil)
        XCTAssertEqual(Place.of("💧 Water: here · 📍 somewhere")?.note, "here · 📍 somewhere")
    }

    func testCheckInPositionsStillParse() {
        XCTAssertEqual(CheckIn.spot(in: CheckIn.safe.text(battery: 5, spot: gym)), gym)
        XCTAssertNil(CheckIn.spot(in: Place(kind: .water, note: "", spot: gym).text)) // a place is not a check-in
    }
}
