import XCTest
@testable import BlackoutCore

private let m1 = "00000000000000a1"

/// Same scenarios as the Android CoreTest (router and crypto parts), plus checks of the Swift storage pruning.
final class CoreTests: XCTestCase {
    /// Simulated network: links deliver queued packets through encode/decode, like a real transport.
    final class Net {
        var nodes: [String: MeshRouter] = [:]
        var got: [String: [String]] = [:]
        var q: [(from: String, to: String, p: Packet)] = []
        func add(_ n: String) {
            got[n] = []
            nodes[n] = MeshRouter(send: { [unowned self] peer, p in q.append((n, peer, p)) },
                                  deliver: { [unowned self] p in got[n]!.append(p.id) })
        }
        func link(_ a: String, _ b: String) { nodes[a]!.peerUp(b); nodes[b]!.peerUp(a); pump() }
        func cut(_ a: String, _ b: String) { nodes[a]!.peerDown(b); nodes[b]!.peerDown(a) }
        func pump() {
            while !q.isEmpty { let (f, t, p) = q.removeFirst(); nodes[t]!.receive(from: f, Packet.decode(p.encode())!) }
        }
    }
    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func pkt(_ id: String, ttl: Int = 16) -> Packet { Packet(id: id, ts: now(), ttl: ttl, cipher: Data([1])) }

    func testMultiHopChainDeliversOnce() {
        let n = Net(); ["a", "b", "c", "d"].forEach(n.add)
        n.link("a", "b"); n.link("b", "c"); n.link("c", "d"); n.link("d", "a")
        n.nodes["a"]!.publish(pkt(m1)); n.pump()
        XCTAssertEqual(n.got["c"], [m1]); XCTAssertEqual(n.got["b"], [m1]); XCTAssertEqual(n.got["d"], [m1])
        XCTAssertEqual(n.got["a"], [])
    }

    func testStoredMessageCrossesWhenCarrierMoves() {
        let n = Net(); ["a", "b", "c"].forEach(n.add); n.link("a", "b")
        n.nodes["a"]!.publish(pkt(m1)); n.pump(); n.cut("a", "b"); n.link("b", "c")
        XCTAssertEqual(n.got["c"], [m1])
    }

    func testTtlStopsPacket() {
        let n = Net(); ["a", "b", "c"].forEach(n.add); n.link("a", "b"); n.link("b", "c")
        n.nodes["a"]!.publish(pkt(m1, ttl: 2)); n.pump()
        XCTAssertEqual(n.got["b"], [m1]); XCTAssertEqual(n.got["c"], [])
    }

    func testCryptoRoundTripAndWrongCodeAndTamper() throws {
        let c = GroupCrypto(code: "group-code")
        let p = Packet(id: m1, ts: 5, ttl: 16, cipher: try c.seal(id: m1, ts: 5, sender: "s", name: "Max", text: "hello"))
        XCTAssertEqual(c.open(Packet.decode(p.encode())!)?.text, "hello")
        XCTAssertNil(GroupCrypto(code: "other-code").open(p))
        XCTAssertNil(c.open(Packet(id: m1, ts: 6, ttl: 16, cipher: p.cipher)))  // timestamp is authenticated
        XCTAssertNotNil(c.open(p.withTtl(3)))                                  // ttl is not, so relays can lower it
    }

    func testGarbageRejected() {
        XCTAssertNil(Packet.decode(Data([0, 1, 2])))
        XCTAssertNil(Packet.decode(Data([Packet.marker] + [UInt8](repeating: 0, count: 17))))  // header only
        var tooManyHops = pkt(m1).encode(); tooManyHops[17] = 65
        XCTAssertNil(Packet.decode(tooManyHops))
    }

    func testNegativeAndLargeTimestampsRoundTrip() {
        for ts: Int64 in [-1, 0, Int64.max, Int64.min] {
            XCTAssertEqual(Packet.decode(Packet(id: m1, ts: ts, ttl: 3, cipher: Data([9])).encode())?.ts, ts)
        }
    }

    func testStorageKeepsNewestUpToCapAndDropsExpired() {
        var t: Int64 = 1_000_000_000
        var sent: [String] = []
        let r = MeshRouter(send: { _, p in sent.append(p.id) }, deliver: { _ in }, now: { t }, retentionMs: 1000, maxStored: 3)
        r.publish(Packet(id: "00000000000000b0", ts: t - 1001, ttl: 16, cipher: Data([1])))  // already expired
        for i in 1...5 { r.publish(Packet(id: "00000000000000b\(i)", ts: t, ttl: 16, cipher: Data([1]))) }
        r.peerUp("x")
        XCTAssertEqual(sent, ["00000000000000b3", "00000000000000b4", "00000000000000b5"])
        t += 1001; sent = []; r.peerUp("y")
        XCTAssertEqual(sent, [])
    }

    func testNewIdIsSixteenHexChars() {
        let id = Packet.newId()
        XCTAssertEqual(id.count, 16); XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(id, Packet.newId())
    }
    // MARK: spec "Forwarding rules": timestamps and ttl (same vectors as Android's CoreTest)

    func testPacketsFromTheFutureAreDropped() {
        let t: Int64 = 1_800_000_000_000
        var got: [String] = []
        let r = MeshRouter(send: { _, _ in }, deliver: { got.append($0.id) }, now: { t })
        r.receive(from: "p", Packet(id: "00000000000000c1", ts: t + MeshRouter.maxFutureMs + 1, ttl: 16, cipher: Data([1])))
        r.receive(from: "p", Packet(id: "00000000000000c2", ts: t + MeshRouter.maxFutureMs, ttl: 16, cipher: Data([1])))
        XCTAssertEqual(got, ["00000000000000c2"])
        var sent: [String] = []
        let r2 = MeshRouter(send: { _, p in sent.append(p.id) }, deliver: { _ in }, now: { t })
        r2.restore([Packet(id: "00000000000000c3", ts: t + 3_600_000, ttl: 16, cipher: Data([1])),
                    Packet(id: "00000000000000c4", ts: t, ttl: 16, cipher: Data([1]))])
        r2.peerUp("x")
        XCTAssertEqual(sent, ["00000000000000c4"]) // the forged future packet is not kept
    }

    func testTtlAbove16IsLowered() {
        var delivered: [Int] = [], forwarded: [Int] = []
        let r = MeshRouter(send: { _, p in forwarded.append(p.ttl) }, deliver: { delivered.append($0.ttl) })
        r.peerUp("a"); r.peerUp("b")
        r.receive(from: "a", Packet(id: "00000000000000d1", ts: now(), ttl: 64, cipher: Data([1])))
        XCTAssertEqual(delivered, [16]) // stored with 16
        XCTAssertEqual(forwarded, [15]) // and passed on with 15
        var sent: [Int] = []
        let r2 = MeshRouter(send: { _, p in sent.append(p.ttl) }, deliver: { _ in })
        r2.restore([Packet(id: "00000000000000d2", ts: now(), ttl: 40, cipher: Data([1]))]); r2.peerUp("x")
        XCTAssertEqual(sent, [15])
    }

    func testRestoreSendsNewPacketsToPeersAlreadyLinked() {
        var sent: [String] = []
        let r = MeshRouter(send: { _, p in sent.append(p.id) }, deliver: { _ in })
        r.peerUp("x")
        r.restore([Packet(id: "00000000000000e1", ts: now(), ttl: 16, cipher: Data([1]))])
        XCTAssertEqual(sent, ["00000000000000e1"])
    }

    func testRestoredSeenIdsAreNotDeliveredAgain() {
        var got: [String] = []
        let r = MeshRouter(send: { _, _ in }, deliver: { got.append($0.id) })
        r.restore([], seenIds: [m1])
        r.receive(from: "peer", pkt(m1))
        XCTAssertEqual(got, [])
        r.receive(from: "peer", pkt("00000000000000b2"))
        XCTAssertEqual(got, ["00000000000000b2"])
    }

    // MARK: spec "Storage": the store cap

    func testStoreCapDropsUnreadableThenPublicThenGroup() {
        let e = [StoreCap.Entry(id: "g1", ts: 1, size: 100, kind: .group), StoreCap.Entry(id: "p1", ts: 2, size: 100, kind: .isPublic),
                 StoreCap.Entry(id: "u2", ts: 5, size: 100, kind: .unreadable), StoreCap.Entry(id: "u1", ts: 3, size: 100, kind: .unreadable),
                 StoreCap.Entry(id: "p2", ts: 4, size: 100, kind: .isPublic), StoreCap.Entry(id: "g2", ts: 6, size: 100, kind: .group)]
        XCTAssertEqual(StoreCap.overflow(e, maxBytes: 600, maxCount: 6), [])
        XCTAssertEqual(StoreCap.overflow(e, maxBytes: 300, maxCount: 6), ["u1", "u2", "p1"])
        XCTAssertEqual(StoreCap.overflow(e, maxBytes: 10_000, maxCount: 1), ["u1", "u2", "p1", "p2", "g1"])
        XCTAssertEqual(StoreCap.overflow(e, maxBytes: 550, maxCount: 6), ["u1"])
    }

    // MARK: spec "Wi-Fi networks": duplicate links

    func testDuplicateLinkRuleIsTheSameOnBothPhones() {
        let a = "259b6c4d-e98", b = "7c0d995b-2c4" // a < b
        // Both dialed at about the same time: both keep the link a dialed.
        XCTAssertFalse(DuplicateLinks.keepNew(myId: a, remoteId: b, newDialedByMe: false, oldDialedByMe: true, oldAgeMs: 500))
        XCTAssertTrue(DuplicateLinks.keepNew(myId: b, remoteId: a, newDialedByMe: false, oldDialedByMe: true, oldAgeMs: 500))
        XCTAssertTrue(DuplicateLinks.keepNew(myId: a, remoteId: b, newDialedByMe: true, oldDialedByMe: false, oldAgeMs: 500))
        XCTAssertFalse(DuplicateLinks.keepNew(myId: b, remoteId: a, newDialedByMe: true, oldDialedByMe: false, oldAgeMs: 500))
        // The same phone dialed again (a restart), or the old link is older: the new one replaces it.
        XCTAssertTrue(DuplicateLinks.keepNew(myId: a, remoteId: b, newDialedByMe: false, oldDialedByMe: false, oldAgeMs: 500))
        XCTAssertTrue(DuplicateLinks.keepNew(myId: a, remoteId: b, newDialedByMe: false, oldDialedByMe: true, oldAgeMs: 10_000))
    }

    func testRecentIdsForgetTheOldest() {
        var r = RecentIds(max: 3, ["a", "b"])
        XCTAssertTrue(r.add("c")); XCTAssertFalse(r.add("a")); XCTAssertTrue(r.add("d"))
        XCTAssertEqual(r.list, ["b", "c", "d"]); XCTAssertFalse(r.contains("a"))
    }

    func testReceiptsWaitForAQuietMomentButNotLong() {
        XCTAssertFalse(ReceiptBatch.due(firstMs: 0, lastMs: 0, nowMs: 1_999))
        XCTAssertTrue(ReceiptBatch.due(firstMs: 0, lastMs: 0, nowMs: 2_000))
        XCTAssertFalse(ReceiptBatch.due(firstMs: 0, lastMs: 9_000, nowMs: 9_999)) // still arriving
        XCTAssertTrue(ReceiptBatch.due(firstMs: 0, lastMs: 9_500, nowMs: 10_000)) // but at most 10 s
    }
}
