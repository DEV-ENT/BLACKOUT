import XCTest
@testable import BlackoutCore

/// Group codes, invites, fingerprints, Plus Codes, status text, check-in extensions, reports, "are you safe?" and place
/// freshness, checked against spec/test-vectors.txt. Android's SharedVectorsTest checks the same vectors.
final class SharedVectorsTests: XCTestCase {
    private func of(_ kind: String) -> [[String: String]] {
        let v = VectorsTests.vectors.filter { $0["kind"] == kind }
        XCTAssertFalse(v.isEmpty, "no \(kind) vectors")
        return v
    }
    private func status(_ s: String) -> CheckIn { s == "safe" ? .safe : .help }
    private func needs(_ v: [String: String]) -> Set<Need> {
        Set((v["needs"]?.split(separator: ",") ?? []).map { Need(rawValue: String($0))! })
    }
    private func spot(_ v: [String: String]) -> Spot? {
        v["lat"].map { Spot(lat: Double($0)!, lon: Double(v["lon"]!)!, accuracy: v["accuracy"].map { Int($0)! }) }
    }

    func testVectorCounts() {
        XCTAssertEqual(of("code-normalize").count, 13)
        XCTAssertEqual(of("invite").count, 2)
        XCTAssertEqual(of("invite-parse").count, 10)
        XCTAssertEqual(of("fingerprint").count, 3)
        XCTAssertEqual(of("pluscode").count, 4)
        XCTAssertEqual(of("status-share").count, 3)
        XCTAssertEqual(of("checkin").count, 4)
        XCTAssertEqual(of("vouch").count, 3)
        XCTAssertEqual(of("ask").count, 2)
    }

    func testCodeNormalize() {
        for v in of("code-normalize") {
            let input = v["input"] ?? String(decoding: Hex.decode(v["input_hex"]!), as: UTF8.self)
            let out = Invite.normalizeCode(input)
            XCTAssertEqual(out, v["output"], "\(v)")
            XCTAssertEqual(Invite.isGeneratedCode(out), v["generated"] == "true", "\(v)")
        }
    }

    func testInviteLinks() {
        for v in of("invite") {
            let name = v["name"]!, code = v["code"]!
            XCTAssertEqual(Invite.url(name: name, code: code).absoluteString, v["url"])
            XCTAssertEqual(Invite.webUrl(name: name, code: code).absoluteString, v["web"])
            for link in [v["url"]!, v["web"]!] {
                XCTAssertEqual(Invite.parse(link)?.name, name); XCTAssertEqual(Invite.parse(link)?.code, code)
                XCTAssertEqual(Invite.parse(URL(string: link)!)?.code, code)
            }
        }
    }

    func testInviteParse() {
        for v in of("invite-parse") {
            let i = Invite.parse(v["link"]!)
            XCTAssertEqual(i?.name, v["code"] == nil ? nil : v["name"], v["link"]!)
            XCTAssertEqual(i?.code, v["code"], v["link"]!)
        }
    }

    func testFingerprints() {
        for v in of("fingerprint") {
            let idx = Fingerprint.forCode(v["code"]!)
            XCTAssertEqual(idx.map(String.init).joined(separator: " "), v["indices"])
            XCTAssertEqual(Fingerprint.emojiText(idx), v["emoji"])
            XCTAssertEqual(Fingerprint.spoken(idx), v["spoken"])
        }
        let list = of("fingerprint-list")[0]
        XCTAssertEqual(list["emoji"]!.components(separatedBy: " "), Fingerprint.emoji)
        XCTAssertEqual(list["names"]!.components(separatedBy: ","), Fingerprint.names)
        XCTAssertEqual(Set(Fingerprint.emoji).count, 64)
    }

    func testPlusCodes() {
        for v in of("pluscode") {
            let code = PlusCode.encode(lat: Double(v["lat"]!)!, lon: Double(v["lon"]!)!)
            XCTAssertEqual(code, v["code"])
            let c = PlusCode.decode(code!)!.center
            XCTAssertEqual(c.lat, Double(v["center_lat"]!)!, accuracy: 1e-9)
            XCTAssertEqual(c.lon, Double(v["center_lon"]!)!, accuracy: 1e-9)
        }
    }

    func testStatusShare() {
        for v in of("status-share") {
            let t = StatusShare.text(status(v["status"]!), name: v["name"]!, battery: v["battery"].map { Int($0)! }, spot: spot(v))
            XCTAssertEqual(t, v["text"])
            XCTAssertLessThanOrEqual(t.utf16.count, 160)
        }
    }

    func testCheckIns() {
        for v in of("checkin") {
            let s = status(v["status"]!), text = v["text"]!
            let battery = v["battery"].map { Int($0)! }, people = v["people"].map { Int($0)! }
            XCTAssertEqual(s.text(battery: battery, spot: spot(v), needs: needs(v), people: people), text)
            XCTAssertEqual(CheckIn.of(text), s)
            XCTAssertEqual(CheckIn.needs(in: text), needs(v))
            XCTAssertEqual(CheckIn.people(in: text), people)
            XCTAssertEqual(CheckIn.battery(in: text), battery)
            XCTAssertEqual(CheckIn.spot(in: text), spot(v))
        }
    }

    func testVouches() {
        for v in of("vouch") {
            let vouch = Vouch(subject: v["subject"]!, status: status(v["status"]!), needs: needs(v),
                              people: v["people"].map { Int($0)! }, spot: spot(v))
            XCTAssertEqual(vouch.text, v["text"])
            XCTAssertEqual(Vouch.of(v["text"]!), vouch)
            XCTAssertNil(CheckIn.of(vouch.text)) // never the sender's own check-in
        }
    }

    func testAsks() {
        for v in of("ask") {
            XCTAssertEqual(AreYouSafe(to: v["to"]).text, v["text"])
            XCTAssertEqual(AreYouSafe.of(v["text"]!), AreYouSafe(to: v["to"]))
        }
    }

    func testPlaceFreshness() {
        let now: Int64 = 1_793_807_238_631
        for c in of("place-freshness")[0]["cases"]!.split(separator: " ") {
            let parts = c.split(separator: "=")
            let expected: Freshness = parts[1] == "fresh" ? .fresh : parts[1] == "old" ? .old : .expired
            XCTAssertEqual(Place.freshness(ts: now - Int64(parts[0])!, now: now), expected, String(c))
        }
    }
}
