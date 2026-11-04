import XCTest
@testable import BlackoutCore

private let m1 = "00000000000000a1"

/// Same scenarios as the LoRa tests in the Android CoreTest, plus a frame written out by hand from the protobuf spec.
final class MeshtasticTests: XCTestCase {
    func testToRadioBytesMatchHandEncodedProtobuf() {
        // ToRadio{ packet(1): MeshPacket{ to(2,fixed32)=0xFFFFFFFF, decoded(4)=Data{ portnum(1)=256, payload(2)=AA BB },
        //          id(6,fixed32)=0x01020304, hop_limit(9)=3 } }
        let expected = Data([0x0A, 0x15,
                             0x15, 0xFF, 0xFF, 0xFF, 0xFF,
                             0x22, 0x07, 0x08, 0x80, 0x02, 0x12, 0x02, 0xAA, 0xBB,
                             0x35, 0x04, 0x03, 0x02, 0x01,
                             0x48, 0x03])
        XCTAssertEqual(Meshtastic.toRadioPacket(Data([0xAA, 0xBB]), packetId: 0x0102_0304), expected)
    }

    func testLoraFrameRoundTrip() {
        let p = Packet(id: m1, ts: 7, ttl: 16, cipher: Data(repeating: 9, count: 100))
        let frame = Meshtastic.toRadioPacket(p.encode(), packetId: 0x0102_0304)
        let data = Meshtastic.fieldBytes(Meshtastic.fieldBytes(frame, 1)!, 4)!
        XCTAssertEqual(Packet.decode(Meshtastic.fieldBytes(data, 2)!)?.id, p.id)
        // FromRadio.packet (field 2) carries the same MeshPacket
        let mesh = Meshtastic.fieldBytes(frame, 1)!
        let from = Data([0x12]) + Meshtastic.varint(UInt64(mesh.count)) + mesh
        XCTAssertEqual(Packet.decode(Meshtastic.parseFromRadio(from).payload!)?.id, p.id)
    }

    func testConfigCompleteAndOtherPortsParsed() {
        XCTAssertEqual(Meshtastic.parseFromRadio(Data([0x38, 42])).configComplete, 42)
        let data = Data([0x08, 0x01, 0x12, 0x01, 0x41]) // TEXT_MESSAGE_APP
        let pkt = Data([0x22, UInt8(data.count)]) + data
        XCTAssertNil(Meshtastic.parseFromRadio(Data([0x12, UInt8(pkt.count)]) + pkt).payload)
        XCTAssertEqual(Meshtastic.parseFromRadio(Data([0x12, 0x40, 0x01])), .init(payload: nil, configComplete: nil)) // truncated
    }

    func testWantConfigBytes() { XCTAssertEqual(Meshtastic.wantConfig(42), Data([0x18, 42])) }

    func testLoraMessageFitsAtLimit() throws {
        let c = GroupCrypto(code: "group-code"), id = Packet.newId()
        let p = Packet(id: id, ts: 1, ttl: 16, cipher: try c.seal(id: id, ts: 1, sender: "abcdef012345", name: "Massimiliano Rossi", text: String(repeating: "x", count: 140)))
        XCTAssertTrue(Meshtastic.fits(p), "\(p.encode().count)")
        let q = Packet(id: id, ts: 1, ttl: 16, cipher: try c.seal(id: id, ts: 1, sender: "abcdef012345", name: "Massimiliano Rossi", text: String(repeating: "x", count: 400)))
        XCTAssertFalse(Meshtastic.fits(q))
    }

    func testQueuePacesDropsOldAndOversize() {
        var t: Int64 = 1_000_000_000
        let q = LoraQueue(now: { t })
        q.offer(Packet(id: m1, ts: t, ttl: 16, cipher: Data(count: 10))); q.offer(Packet(id: m1, ts: t, ttl: 15, cipher: Data(count: 10)))
        q.offer(Packet(id: "00000000000000a2", ts: t - LoraQueue.maxAgeMs - 1, ttl: 16, cipher: Data(count: 10)))
        q.offer(Packet(id: "00000000000000a3", ts: t, ttl: 16, cipher: Data(count: 400)))
        q.offer(Packet(id: "00000000000000a4", ts: t, ttl: 16, cipher: Data(count: 10)))
        XCTAssertEqual(q.next()?.id, m1); XCTAssertNil(q.next())
        t += LoraQueue.intervalMs; XCTAssertEqual(q.next()?.id, "00000000000000a4")
        t += LoraQueue.intervalMs; XCTAssertNil(q.next())
    }
}
