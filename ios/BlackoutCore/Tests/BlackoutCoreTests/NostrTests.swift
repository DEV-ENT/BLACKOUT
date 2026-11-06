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

    func testLiveAndCatchUpFilters() throws {
        let req = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Nostr.live("s", mailboxes: [0xa8d0, 0x0794], now: 1_793_990_000).utf8)) as? [Any])
        let f = try XCTUnwrap(req[2] as? [String: Any])
        XCTAssertEqual(f["kinds"] as? [Int], [Nostr.kind])
        XCTAssertEqual(f["#t"] as? [String], ["dp1-a8d0", "dp1-0794"])
        XCTAssertEqual(f["since"] as? Int64, 1_793_990_000 - Nostr.keepSeconds); XCTAssertEqual(f["limit"] as? Int, 1)
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Nostr.catchUp("c", mailbox: 0xa8d0, since: 1_793_000_000, until: 1_793_500_000).utf8)) as? [Any])
        XCTAssertEqual(page[1] as? String, "c")
        let pf = try XCTUnwrap(page[2] as? [String: Any])
        XCTAssertEqual(pf["#t"] as? [String], ["dp1-a8d0"])
        XCTAssertEqual(pf["since"] as? Int64, 1_793_000_000); XCTAssertEqual(pf["until"] as? Int64, 1_793_500_000)
        XCTAssertEqual(pf["limit"] as? Int, 500)
        let open = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Nostr.catchUp("c", mailbox: 0x0794, since: 1, until: nil).utf8)) as? [Any])
        XCTAssertNil((open[2] as? [String: Any])?["until"])
        let have = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Nostr.have("h", packetIds: ["a8d0000000000001", "07940000000000ff"]).utf8)) as? [Any])
        let hf = try XCTUnwrap(have[2] as? [String: Any])
        XCTAssertEqual(hf["#x"] as? [String], ["a8d0000000000001", "07940000000000ff"]); XCTAssertEqual(hf["limit"] as? Int, 2)
    }

    func testAnswersAndEnds() {
        let ok = Nostr.ok("[\"OK\",\"ev1\",true,\"\"]")
        XCTAssertEqual(ok?.eventId, "ev1"); XCTAssertEqual(ok?.accepted, true)
        XCTAssertEqual(Nostr.ok("[\"OK\",\"ev1\",false,\"duplicate: already have this event\"]")?.accepted, true)
        let no = Nostr.ok("[\"OK\",\"ev2\",false,\"blocked: web of trust\"]")
        XCTAssertEqual(no?.accepted, false); XCTAssertEqual(no?.reason, "blocked: web of trust")
        XCTAssertNil(Nostr.ok("[\"EOSE\",\"s\"]"))
        XCTAssertTrue(Nostr.end("[\"EOSE\",\"cu1\"]").map { $0.subId == "cu1" && $0.complete } == true)
        XCTAssertEqual(Nostr.end("[\"CLOSED\",\"cu1\",\"rate-limited: slow down\"]")?.complete, false)
        XCTAssertNil(Nostr.end("[\"NOTICE\",\"hi\"]"))
    }

    private let packet = Packet(id: "a8d0000000000001", ts: 1_793_990_000_000, ttl: 16, cipher: Data([1, 2, 3]))

    /// Same vector as Android's NostrTest: SHA-256 of ts and cipher, first 16 bytes; ttl doesn't count.
    func testDigestIgnoresTtl() {
        XCTAssertEqual(Nostr.digest(packet), "b37c0505ae1f3a3b344182cf27f29431")
        XCTAssertEqual(Nostr.digest(packet), Nostr.digest(packet.withTtl(3)))
        XCTAssertNotEqual(Nostr.digest(packet), Nostr.digest(Packet(id: packet.id, ts: packet.ts, ttl: 16, cipher: Data([1, 2, 4]))))
    }

    func testRelaySinceRoundTripsAndOnlyMovesForward() {
        let s = RelaySince()
        s.advance("wss://a", 0xa8d0, to: 100); s.advance("wss://a", 0xa8d0, to: 50); s.advance("wss://b", 0x0794, to: 7)
        let saved = s.save()
        XCTAssertEqual(saved, "wss://a|a8d0=100,wss://b|0794=7")
        let t = RelaySince(saved)
        XCTAssertEqual(t.get("wss://a", 0xa8d0), 100); XCTAssertEqual(t.get("wss://b", 0x0794), 7); XCTAssertNil(t.get("wss://b", 0xa8d0))
    }

    /// Same scenario as Android's NostrTest.catchUpPagesOneMailboxAtATime.
    func testCatchUpPagesOneMailboxAtATime() throws {
        let since = RelaySince(); since.advance("wss://r", 0xa8d0, to: 1_000_000)
        let now: Int64 = 1_100_000
        let cu = CatchUp(relay: "wss://r", since: since)
        cu.add([0xa8d0, 0xbeef, Nostr.publicMailbox])
        let first = try XCTUnwrap(cu.next(now: now))
        XCTAssertEqual(first.mailbox, 0xa8d0); XCTAssertEqual(first.since, 1_000_000 - Nostr.sinceMarginSeconds); XCTAssertNil(first.until)
        XCTAssertNil(cu.next(now: now))                                   // one REQ at a time
        for i in 0..<Int64(Nostr.page) { cu.event(first.subId, createdAt: 1_050_000 - i) } // a full page: an older one follows
        let second = try XCTUnwrap(cu.end(first.subId, complete: true, now: now))
        XCTAssertEqual(second.mailbox, 0xa8d0); XCTAssertEqual(second.until, 1_050_000 - Int64(Nostr.page) + 1); XCTAssertEqual(second.since, first.since)
        for _ in 0..<3 { cu.event(second.subId, createdAt: 1_000_000) }
        let third = try XCTUnwrap(cu.end(second.subId, complete: true, now: now)) // not full: the next mailbox
        XCTAssertEqual(third.mailbox, 0xbeef); XCTAssertEqual(third.since, now - Nostr.keepSeconds)
        XCTAssertEqual(since.get("wss://r", 0xa8d0), now)                 // caught up to when the catch-up started
        let fourth = try XCTUnwrap(cu.end(third.subId, complete: false, now: now)) // refused: not caught up, next mailbox
        XCTAssertNil(since.get("wss://r", 0xbeef))
        XCTAssertEqual(fourth.mailbox, Nostr.publicMailbox)
        for _ in 0..<Nostr.page { cu.event(fourth.subId, createdAt: 1_090_000) }
        XCTAssertNil(cu.end(fourth.subId, complete: true, now: now))      // the Public channel gets one page only
        XCTAssertEqual(since.get("wss://r", Nostr.publicMailbox), now)
        cu.live(0xa8d0, createdAt: now + 50, now: now + 60); XCTAssertEqual(since.get("wss://r", 0xa8d0), now + 50)
        cu.live(0xa8d0, createdAt: now + 9_999, now: now + 70); XCTAssertEqual(since.get("wss://r", 0xa8d0), now + 70) // never past now
        cu.live(0xbeef, createdAt: now + 80, now: now + 90); XCTAssertNil(since.get("wss://r", 0xbeef))                 // not caught up here
        let again = CatchUp(relay: "wss://r", since: RelaySince()); again.add([0x0001])
        let p1 = try XCTUnwrap(again.next(now: now)); for _ in 0..<Nostr.page { again.event(p1.subId, createdAt: 5) }
        let p2 = try XCTUnwrap(again.end(p1.subId, complete: true, now: now)); XCTAssertEqual(p2.until, 5)
        for _ in 0..<Nostr.page { again.event(p2.subId, createdAt: 5) }
        XCTAssertEqual(again.end(p2.subId, complete: true, now: now)?.until, 4) // a full second: step past it
    }

    private func pkt(_ n: Int, _ ts: Int64, _ cipher: Data? = nil) -> Packet {
        Packet(id: "a8d0" + String(format: "%012x", n), ts: ts, ttl: 15, cipher: cipher ?? Data([UInt8(truncatingIfNeeded: n)]))
    }

    /// Same as Android's bridgedPacketsWaitBeforeTheLookup.
    func testBridgedPacketsWaitBeforeTheLookup() throws {
        var t: Int64 = 1_800_000_000_000
        let o = RelayOutbox(now: { t }, jitter: { 20_000 })
        o.offer(pkt(1, t - 1_000), mine: false)
        XCTAssertTrue(o.toCheck(50).isEmpty)                    // not yet: another phone may post it first
        t += 20_000
        XCTAssertEqual(o.toCheck(50).map(\.id), [pkt(1, 0).id])
        o.offer(pkt(2, t - 1_000), mine: true)                  // own packets never wait
        XCTAssertEqual(try XCTUnwrap(o.next(bridged: false)).packet.id, pkt(2, 0).id)
    }

    /// Same scenario as Android's NostrTest.outboxCountsSentOnlyWhenARelayAccepts.
    func testOutboxCountsSentOnlyWhenARelayAccepts() throws {
        var t: Int64 = 1_800_000_000_000
        let o = RelayOutbox(now: { t }, jitter: { 0 })
        o.offer(pkt(1, t - 1_000), mine: true)                 // fresh own: straight up
        o.offer(pkt(2, t - 5 * 60_000), mine: true)            // older own: looked up first
        o.offer(pkt(3, t - 8 * 24 * 3_600_000), mine: false)   // too old: never
        let (p1, own) = try XCTUnwrap(o.next(bridged: false))
        XCTAssertEqual(p1.id, pkt(1, 0).id); XCTAssertTrue(own); XCTAssertNil(o.next(bridged: true))
        o.posted(eventId: "ev1", p1, fromOwn: own, relays: ["r1", "r2"])
        XCTAssertNil(o.answer(relay: "r1", Nostr.Ok(eventId: "ev1", accepted: false, reason: "blocked: not in web of trust")))
        XCTAssertFalse(o.isSent(p1.id))
        XCTAssertEqual(o.answer(relay: "r2", Nostr.Ok(eventId: "ev1", accepted: true, reason: "")), p1.id) // sent once one relay took it
        XCTAssertTrue(o.isSent(p1.id)); XCTAssertTrue(o.changed); XCTAssertEqual(o.sentList(), [p1.id]); XCTAssertFalse(o.changed)
        o.offer(p1, mine: true); XCTAssertNil(o.next(bridged: true))      // never twice

        // #x lookup: a relay copy with other contents doesn't count
        let batch = o.toCheck(50); XCTAssertEqual(batch.map(\.id), [pkt(2, 0).id])
        _ = o.fromRelay(Packet(id: batch[0].id, ts: batch[0].ts, ttl: 9, cipher: Data([99])))
        XCTAssertEqual(o.checked(batch), [])
        let (p2, own2) = try XCTUnwrap(o.next(bridged: true)); XCTAssertEqual(p2.id, batch[0].id); XCTAssertFalse(own2)

        // every relay refused: queued again, at most 3 tries
        o.posted(eventId: "ev2", p2, fromOwn: own2, relays: ["r1"])
        _ = o.answer(relay: "r1", Nostr.Ok(eventId: "ev2", accepted: false, reason: "invalid: too large"))
        let again = try XCTUnwrap(o.next(bridged: true)); XCTAssertEqual(again.packet.id, p2.id)
        o.posted(eventId: "ev3", again.packet, fromOwn: false, relays: ["r1"])
        t += RelayOutbox.answerMs; o.expire()                              // no answer in 30 s
        let third = try XCTUnwrap(o.next(bridged: true)); XCTAssertEqual(third.packet.id, p2.id)
        o.posted(eventId: "ev4", third.packet, fromOwn: false, relays: ["r1"])
        _ = o.answer(relay: "r1", Nostr.Ok(eventId: "ev4", accepted: false, reason: "error"))
        XCTAssertNil(o.next(bridged: true))                                // given up until offered again
        XCTAssertEqual(o.answer(relay: "r1", Nostr.Ok(eventId: "ev3", accepted: true, reason: "")), p2.id) // a late acceptance still counts

        // a relay copy with the same contents (any ttl) means it's there
        let p4 = pkt(4, t - 10 * 60_000); o.offer(p4, mine: false)
        let b2 = o.toCheck(50); _ = o.fromRelay(p4.withTtl(2))
        XCTAssertEqual(o.checked(b2), [p4.id]); XCTAssertTrue(o.isSent(p4.id))
        let p5 = pkt(5, t - 1_000); _ = o.fromRelay(p5); o.offer(p5, mine: true); XCTAssertNil(o.next(bridged: true)) // came from relays
    }

    func testOutboxQueuesKeepTheNewest() throws {
        let t: Int64 = 1_800_000_000_000
        let o = RelayOutbox(now: { t }, jitter: { 0 })
        for i in 0..<(RelayOutbox.ownMax + 10) { o.offer(pkt(i, t - 60_000 + Int64(i)), mine: true) }
        XCTAssertEqual(o.queued, RelayOutbox.ownMax)
        o.offer(pkt(100_000, t - 61_000), mine: true)                     // full, and older than all: not taken
        XCTAssertEqual(o.queued, RelayOutbox.ownMax)
        XCTAssertEqual(o.next(bridged: false)?.packet.id, pkt(RelayOutbox.ownMax + 9, 0).id)
        var last = Int64.max, n = 0
        while let p = o.next(bridged: false)?.packet { XCTAssertLessThan(p.ts, last); last = p.ts; n += 1 }
        XCTAssertEqual(n, RelayOutbox.ownMax - 1); XCTAssertEqual(last, t - 60_000 + 10) // the 10 oldest made room
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
