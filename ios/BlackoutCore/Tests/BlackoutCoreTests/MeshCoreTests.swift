import XCTest
@testable import BlackoutCore

/// The same frames as Android's MeshCoreTest, checked against MeshCore's companion firmware (MyMesh.cpp, v1.18).
final class MeshCoreTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func unhex(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).map { i -> UInt8 in
        let a = s.index(s.startIndex, offsetBy: i); return UInt8(s[a..<s.index(a, offsetBy: 2)], radix: 16)! }) }

    func testChannelKey() { XCTAssertEqual(hex(MeshCore.channelKey), "835a8265454a846068f204bf5ea81bd3") }

    func testCommandFrames() {
        XCTAssertEqual(hex(MeshCore.deviceQuery()), "1603")
        XCTAssertEqual(hex(MeshCore.appStart()), "01" + String(repeating: "00", count: 7) + hex(Data("DarkProof".utf8)))
        XCTAssertEqual(hex(MeshCore.getChannel(3)), "1f03")
        XCTAssertEqual(hex(MeshCore.setChannel(2)),
                       "2002" + hex(Data("#darkproof".utf8)) + String(repeating: "00", count: 22) + "835a8265454a846068f204bf5ea81bd3")
        XCTAssertEqual(MeshCore.sendData(1, unhex("aabb")).map(hex), "3e01ff44ffaabb")
        XCTAssertNil(MeshCore.sendData(1, Data(count: MeshCore.payloadMax + 1)))
        XCTAssertEqual(hex(MeshCore.syncNext()), "0a")
    }

    func testParsesReplies() {
        XCTAssertEqual(MeshCore.deviceInfo(unhex("0d0e2028")), MeshCore.DeviceInfo(firmware: 14, channels: 40))
        XCTAssertNil(MeshCore.deviceInfo(unhex("05")))
        var name = Data("#darkproof".utf8); name.append(Data(count: 22))
        let ours = MeshCore.slot(unhex("1205") + name + MeshCore.channelKey)!
        XCTAssertTrue(ours.isOurs); XCTAssertEqual(ours.idx, 5); XCTAssertEqual(ours.name, "#darkproof")
        let empty = MeshCore.slot(unhex("1207") + Data(count: 48))!
        XCTAssertTrue(empty.isEmpty); XCTAssertFalse(empty.isOurs)
        var pub = Data("Public".utf8); pub.append(Data(count: 26))
        let p = MeshCore.slot(unhex("1200") + pub + unhex("8b3387e9c5cdea6ac9e5edbaa115cd72"))!
        XCTAssertFalse(p.isEmpty); XCTAssertFalse(p.isOurs)
        XCTAssertTrue(MeshCore.isPush(unhex("83"))); XCTAssertFalse(MeshCore.isPush(unhex("0a")))
    }

    func testReadsOnlyDarkProofChannelData() {
        let packet = unhex("b2" + String(repeating: "11", count: 30))
        func frame(_ slot: UInt8, _ type: UInt16) -> Data {
            Data([0x1B, 0x10, 0, 0, slot, 2, UInt8(type & 0xFF), UInt8(type >> 8), UInt8(packet.count)]) + packet
        }
        XCTAssertEqual(MeshCore.packet(frame(4, 0xFF44), slot: 4), packet)
        XCTAssertNil(MeshCore.packet(frame(3, 0xFF44), slot: 4))
        XCTAssertNil(MeshCore.packet(frame(4, 0x0001), slot: 4))
        XCTAssertNil(MeshCore.packet(frame(4, 0xFF44).prefix(20), slot: 4))
        XCTAssertNil(MeshCore.packet(unhex("11"), slot: 4))
    }

    func testCheckInsFitButLongMessagesDont() throws {
        let c = GroupCrypto(code: "group-code")
        func packet(_ name: String, _ text: String) throws -> Packet {
            let id = Packet.newId(); return Packet(id: id, ts: 1, ttl: 16, cipher: try c.seal(id: id, ts: 1, sender: "7c0d995b-2c4", name: name, text: text))
        }
        XCTAssertTrue(MeshCore.fits(try packet("Anna", CheckIn.safe.text(battery: 23, spot: Spot(lat: 45.4642, lon: 9.19, accuracy: 12)))))
        XCTAssertFalse(MeshCore.fits(try packet("Anna", String(repeating: "x", count: 120))))
        let q = LoraQueue(maxBytes: MeshCore.payloadMax, now: { 1 })
        q.offer(try packet("Anna", String(repeating: "x", count: 120))); XCTAssertNil(q.next())
    }
}
