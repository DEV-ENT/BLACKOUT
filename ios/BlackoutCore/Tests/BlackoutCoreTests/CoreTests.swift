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
}
