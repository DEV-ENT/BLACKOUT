import XCTest
@testable import BlackoutCore

/// The same ids and signature as Android's NostrTest (ids checked against Python's json.dumps, the signature against
/// @noble/curves).
final class NostrTests: XCTestCase {
    func testEventIdEscapesLikeNip01() {
        XCTAssertEqual(Nostr.eventId(pubkey: String(repeating: "ab", count: 32), createdAt: 1_700_000_000, kind: 1,
                                     tags: [["t", "x"]], content: "a\"b\\c\nd\te\u{01}é🙂"),
                       "3f0e953ed7197fc8da43de56655cad42cf3a57e4221e66a5f78f6e9e016d9405")
    }

    func testEventMatchesAndroid() throws {
        let p = Packet(id: "a8d0000000000001", ts: 1_793_990_000_000, ttl: 16, cipher: Data([1, 2, 3]))
        var signed: Data?
        let e = Nostr.event(p, pubkey: "6dd447ac274cd77ed2bb1373b5571a181271583014de6a085437d709bc613bd5", now: 1_793_990_000) { m in
            signed = m; return Data(count: 64)
        }
        XCTAssertEqual(e["content"] as? String, "sqjQAAAAAAABAAABobIi/YAQAQID")
        XCTAssertEqual(e["tags"] as? [[String]], [["t", "dp1-a8d0"], ["x", "a8d0000000000001"], ["expiration", "1794594800"]])
        XCTAssertEqual(e["id"] as? String, "f1cfcc88f725896d6159d0035e17e1fca77ad130acc200a2cb798c550df4390a") // Android's EXPECTED_ID
        XCTAssertEqual(signed.map { Hex.encode($0) }, e["id"] as? String) // the signer gets the 32-byte id

        let sk = Hex.decode("c6701f511d184b55bcfb736a7fde240b37d9ae4f8f08eed3e8b5e4ec74416261")
        let real = Nostr.event(p, pubkey: Hex.encode(Schnorr.publicKey(sk)), now: 1_793_990_000) {
            Schnorr.sign(secret: sk, message: $0, aux: Data(repeating: 2, count: 32))
        }
        XCTAssertEqual(real["sig"] as? String, "eefea03d7b56a59850db2ea11651cc3988def98b4c01b1f38c6c42226b64c45a895ba6ccba4e370ca70b0ee19f944b651cb703becee4b177ae5ab21e5c573335") // Android's EXPECTED_SIG

        let wire = "[\"EVENT\",\"s\"," + String(decoding: try JSONSerialization.data(withJSONObject: e), as: UTF8.self) + "]"
        let r = try XCTUnwrap(Nostr.received(wire))
        XCTAssertEqual(r.packet.id, "a8d0000000000001"); XCTAssertEqual(r.eventId, e["id"] as? String)
        XCTAssertNil(Nostr.received("[\"EOSE\",\"s\"]"))
        XCTAssertNil(Nostr.received("[\"EVENT\",\"s\",{\"kind\":1,\"content\":\"hi\"}]"))
        XCTAssertNil(Nostr.received("not json"))
    }

    func testSubscribe() throws {
        let req = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Nostr.subscribe("s", mailboxes: [0xa8d0, 0x0794], now: 1_793_990_000).utf8)) as? [Any])
        let f = try XCTUnwrap(req[2] as? [String: Any])
        XCTAssertEqual(f["kinds"] as? [Int], [Nostr.kind])
        XCTAssertEqual(f["#t"] as? [String], ["dp1-a8d0", "dp1-0794"])
        XCTAssertEqual(f["since"] as? Int64, 1_793_990_000 - Nostr.keepSeconds)
        let have = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Nostr.have("h", packetIds: ["a8d0000000000001", "07940000000000ff"]).utf8)) as? [Any])
        let hf = try XCTUnwrap(have[2] as? [String: Any])
        XCTAssertEqual(hf["#x"] as? [String], ["a8d0000000000001", "07940000000000ff"]); XCTAssertEqual(hf["limit"] as? Int, 2)
    }

    func testTorCheck() {
        XCTAssertTrue(TorCheck.isTor(Data(#"{"IsTor":true,"IP":"185.220.101.1"}"#.utf8)))
        XCTAssertFalse(TorCheck.isTor(Data(#"{"IsTor":false,"IP":"1.2.3.4"}"#.utf8)))
        XCTAssertFalse(TorCheck.isTor(Data("<html>blocked</html>".utf8)))
        XCTAssertFalse(TorCheck.isTor(Data("{}".utf8)))
    }

    func testRefusals() {
        XCTAssertEqual(Nostr.refusal("[\"OK\",\"ab\",false,\"banned: too many rate-limit violations\"]"), "banned: too many rate-limit violations")
        XCTAssertNil(Nostr.refusal("[\"OK\",\"ab\",true,\"duplicate: have it\"]"))
        XCTAssertNil(Nostr.refusal("[\"EOSE\",\"s\"]"))
        XCTAssertTrue(Nostr.isThrottle("rate-limited: slow down") && Nostr.isThrottle("banned: x") && Nostr.isThrottle("rate limited") && !Nostr.isThrottle("invalid: bad sig"))
    }
}
