import XCTest
@testable import BlackoutCore

/// Needs, head counts, reports about others, "are you safe?" and invites. Same cases as Android's CheckInExtrasTest.
final class CheckInExtrasTests: XCTestCase {
    private func m(_ sender: String, _ name: String, _ ts: Int64, _ text: String, isPublic: Bool = false) -> Message {
        Message(id: "\(sender)\(ts)", ts: ts, sender: sender, name: name, text: text, isPublic: isPublic)
    }

    func testOldAppsReadNewCheckIns() {
        // What an app without these extensions reads from them: the same status, battery and position.
        let t = CheckIn.help.text(battery: 9, spot: Spot(lat: 45.4642, lon: 9.19), needs: [.trapped], people: 2)
        XCTAssertEqual(t, "🆘 I need help: trapped · 👥 2 · 🔋 9% · 📍 45.46420,9.19000")
        XCTAssertEqual(CheckIn.of(t), .help); XCTAssertEqual(CheckIn.battery(in: t), 9); XCTAssertEqual(CheckIn.spot(in: t), Spot(lat: 45.4642, lon: 9.19))
        // ...and new apps read old check-ins.
        XCTAssertTrue(CheckIn.needs(in: "🆘 I need help · 🔋 9%").isEmpty); XCTAssertNil(CheckIn.people(in: "🆘 I need help · 🔋 9%"))
    }

    func testNeedsAndPeopleParsing() {
        XCTAssertEqual(CheckIn.needs(in: "🆘 I need help: Water, rope,injured · 👥 3"), [.water, .injured])
        XCTAssertTrue(CheckIn.needs(in: "🆘 trapped under the bridge").isEmpty)      // free text is not a list
        XCTAssertTrue(CheckIn.needs(in: "✅ I'm safe: water").isEmpty)
        XCTAssertEqual(CheckIn.help.text(battery: nil, needs: [.water], people: 0), "🆘 I need help: water")
        XCTAssertEqual(CheckIn.safe.text(battery: nil, needs: [.water], people: 100), "✅ I'm safe") // needs only for help
        XCTAssertNil(CheckIn.people(in: "✅ I'm safe · 👥 0")); XCTAssertNil(CheckIn.people(in: "✅ I'm safe · 👥 100"))
        XCTAssertNil(CheckIn.people(in: "✅ I'm safe · 👥 3x")); XCTAssertNil(CheckIn.people(in: "We are 👥 3")) // not a check-in
        XCTAssertEqual(CheckIn.people(in: "✅ I'm safe · 👥 2 people · 👥 5"), 5)
        XCTAssertEqual(Need.allCases.map(\.label), ["Injured", "Trapped", "Need water", "Need food", "Need medicine", "Need shelter"])
    }

    func testVouchesAreNeverOwnCheckIns() {
        XCTAssertEqual(Vouch(subject: " ", status: .safe).text, "👤 Someone is safe")
        XCTAssertEqual(Vouch(subject: "Nonna\n Maria · Rossi Bianchi", status: .safe).text, "👤 Nonna Maria Rossi Bianch is safe") // one line, 24 chars
        XCTAssertEqual(Vouch.of("👤 Bob is safe is safe"), Vouch(subject: "Bob is safe", status: .safe))
        XCTAssertEqual(Vouch.of("👤 Ann needs help: food, hugs"), Vouch(subject: "Ann", status: .help, needs: [.food]))
        XCTAssertNil(Vouch.of("👤 my new profile picture")); XCTAssertNil(Vouch.of("👤  is safe")); XCTAssertNil(Vouch.of("👤 Ann needs helpers"))
        XCTAssertNil(Vouch.of("Grandma is safe")); XCTAssertNil(Place.of(Vouch(subject: "Ann", status: .safe).text))
        XCTAssertEqual(Vouch.key("  Grandma\tROSA "), "grandma rosa")
    }

    func testPeopleListKeysReportsByName() {
        let people = Person.all(in: [
            m("anna", "Anna", 100, Vouch(subject: "Grandma", status: .help, needs: [.medicine], spot: Spot(lat: 45, lon: 9)).text),
            m("me", "Me", 200, Vouch(subject: "grandma ", status: .safe).text),            // reports from this phone count too
            m("bob", "Bob", 150, Vouch(subject: "Marco", status: .safe).text),
            m("marco", "Marco", 300, CheckIn.help.text(battery: 20, needs: [.trapped], people: 2)), // own, newer: hides Bob's report
            m("carl", "Carl", 120, "hi"),
            m("dina", "Dina", 400, Vouch(subject: "Elsa", status: .safe).text, isPublic: true), // Public: ignored
        ], me: "me")
        XCTAssertEqual(people.map(\.id), ["marco", "report:grandma", "bob", "carl", "anna"])
        let g = people[1]
        XCTAssertEqual(g.name, "grandma"); XCTAssertEqual(g.checkIn, .safe); XCTAssertEqual(g.checkInTs, 200)
        XCTAssertEqual(g.reportedBy, "Me"); XCTAssertEqual(g.reporterId, "me"); XCTAssertTrue(g.isReport)
        XCTAssertTrue(g.needs.isEmpty); XCTAssertEqual(g.spot, Spot(lat: 45, lon: 9)); XCTAssertEqual(g.spotTs, 100) // last known position stays
        let marco = people[0]
        XCTAssertFalse(marco.isReport); XCTAssertEqual(marco.needs, [.trapped]); XCTAssertEqual(marco.people, 2); XCTAssertEqual(marco.battery, 20)
        // A report newer than the person's own check-in stays, as a separate entry marked as a report.
        let later = Person.all(in: [m("marco", "Marco", 300, CheckIn.help.rawValue), m("me", "Me", 350, Vouch(subject: "MARCO", status: .safe).text)], me: "me")
        XCTAssertEqual(later.map(\.id), ["marco", "report:marco"])
        XCTAssertEqual(later[1].reportedBy, "Me"); XCTAssertNil(later[0].reportedBy)
    }

    func testAreYouSafe() {
        XCTAssertEqual(AreYouSafe.of(AreYouSafe(to: " Marco\n").text), AreYouSafe(to: "Marco"))
        XCTAssertEqual(AreYouSafe(to: " ").text, "❓ Is everyone safe?")
        XCTAssertTrue(AreYouSafe(to: nil).isFor("Anyone")); XCTAssertTrue(AreYouSafe(to: "marco  rossi").isFor("Marco Rossi"))
        XCTAssertFalse(AreYouSafe(to: "Marco").isFor("Anna"))
        XCTAssertNil(AreYouSafe.of("❓ , are you safe?")); XCTAssertNil(AreYouSafe.of("Is everyone safe?")); XCTAssertNil(AreYouSafe.of("❓ are you safe?"))
        XCTAssertNil(CheckIn.of(AreYouSafe(to: "Marco").text))
    }

    func testInviteCodes() {
        XCTAssertEqual(Invite.normalizeCode(Invite.webUrl(name: "Family", code: "K7QF-2M9X-PA4T-W8RJ").absoluteString), "K7QF-2M9X-PA4T-W8RJ")
        let i = Invite.parse("  " + Invite.webUrl(name: "Family", code: "K7QF-2M9X-PA4T-W8RJ").absoluteString + "\n")
        XCTAssertEqual(i?.name, "Family"); XCTAssertEqual(i?.code, "K7QF-2M9X-PA4T-W8RJ")
        XCTAssertFalse(Invite.isGeneratedCode("k7qf-2m9x-pa4t-w8rj")); XCTAssertFalse(Invite.isGeneratedCode("K7QF2M9XPA4TW8RJ"))
        for _ in 0..<50 {
            let c = Invite.newCode()
            XCTAssertEqual(Invite.normalizeCode(c.lowercased().replacingOccurrences(of: "-", with: " ")), c); XCTAssertTrue(Invite.isGeneratedCode(c))
        }
        XCTAssertTrue(Invite.webUrl(name: "G", code: "K7QF-2M9X-PA4T-W8RJ").absoluteString.hasPrefix(Invite.webPrefix))
    }
}
