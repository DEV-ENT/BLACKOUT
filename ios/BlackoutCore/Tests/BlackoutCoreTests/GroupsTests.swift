import XCTest
@testable import BlackoutCore

final class GroupsTests: XCTestCase {
    func testInviteLinkRoundTrip() {
        let url = Invite.url(name: "Casa di Nonna & co", code: "K7QF-2M9X-PA4T-W8RJ")
        XCTAssertEqual(url.scheme, "blackout")
        let i = Invite.parse(url)
        XCTAssertEqual(i?.name, "Casa di Nonna & co")
        XCTAssertEqual(i?.code, "K7QF-2M9X-PA4T-W8RJ")
    }

    func testInviteKeepsCodesWithSymbols() {
        let code = "our secret+code=1&2 ünïcode"
        XCTAssertEqual(Invite.parse(Invite.url(name: "G", code: code))?.code, code)
    }

    func testInviteRejectsOtherLinks() {
        XCTAssertNil(Invite.parse(URL(string: "https://join?code=ABCDEFGHJK")!))
        XCTAssertNil(Invite.parse(URL(string: "blackout://other?code=ABCDEFGHJK")!))
        XCTAssertNil(Invite.parse(URL(string: "blackout://join?code=short")!))
        XCTAssertNil(Invite.parse(URL(string: "blackout://join?name=x")!))
    }

    func testInviteNameDefaultsAndIsCapped() {
        XCTAssertEqual(Invite.parse(URL(string: "blackout://join?code=ABCDEFGHJK")!)?.name, "Group")
        let long = String(repeating: "x", count: 60)
        XCTAssertEqual(Invite.parse(Invite.url(name: long, code: "ABCDEFGHJK"))?.name.count, Invite.maxGroupName)
    }

    func testNewCodesAreWellFormedAndUnique() {
        let codes = (0..<200).map { _ in Invite.newCode() }
        for c in codes {
            XCTAssertNotNil(c.range(of: "^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$", options: .regularExpression), c)
        }
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func testCheckInPrefixes() {
        XCTAssertEqual(CheckIn.of(CheckIn.safe.rawValue), .safe)
        XCTAssertEqual(CheckIn.of(CheckIn.help.rawValue), .help)
        XCTAssertEqual(CheckIn.of("🆘 trapped on the 3rd floor"), .help)
        XCTAssertNil(CheckIn.of("I'm safe"))
    }

    private func m(_ sender: String, _ name: String, _ ts: Int64, _ text: String = "hi", isPublic: Bool = false) -> Message {
        Message(id: "\(sender)\(ts)", ts: ts, sender: sender, name: name, text: text, isPublic: isPublic)
    }

    func testPeopleFromMessages() {
        let people = Person.all(in: [
            m("a", "Ann", 100),
            m("me", "Me", 110),                          // this phone: left out
            m("b", "Bob", 120, CheckIn.safe.rawValue),
            m("p", "Stranger", 130, isPublic: true),     // Public channel: left out
            m("web-x", "Maria (Wi-Fi board)", 140),      // Wi-Fi board: left out
            m("a", "Ann R.", 150),                       // newest name wins
            m("c", "Cy", 90, CheckIn.help.rawValue),
            m("b", "Bob", 160, "back home"),             // check-in stays after later messages
        ], me: "me")
        XCTAssertEqual(people.map(\.id), ["c", "b", "a"]) // needs help first, then most recently heard
        XCTAssertEqual(people[2].name, "Ann R.")
        XCTAssertEqual(people[1].checkIn, .safe)
        XCTAssertEqual(people[1].lastTs, 160)
        XCTAssertEqual(people[0].checkIn, .help)
    }

    func testLatestCheckInWins() {
        let p = Person.all(in: [m("a", "Ann", 100, CheckIn.help.rawValue), m("a", "Ann", 200, CheckIn.safe.rawValue)], me: "me")
        XCTAssertEqual(p.first?.checkIn, .safe)
        XCTAssertEqual(p.first?.checkInTs, 200)
    }
}
