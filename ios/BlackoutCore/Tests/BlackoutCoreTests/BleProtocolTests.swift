import XCTest
@testable import BlackoutCore

/// Same checks as the Android BleProtocolTest, so both sides speak the same Bluetooth LE protocol.
final class BleProtocolTests: XCTestCase {
    func testServiceUuidIsTheSpecConstant() {
        // spec/FORMAT.md: one service UUID for every Blackout device, whatever its group
        XCTAssertEqual(BleProtocol.service.uuidString.lowercased(), "bec33cd5-a64e-4e1a-b8c1-868db67d0df3")
    }

    func testHelloBytesAndParse() {
        let f = BleProtocol.hello(nodeId: "7c0d995b-2c4")
        XCTAssertEqual(f, Data([1, 0, 13, 1]) + Data("7c0d995b-2c4".utf8))
        XCTAssertEqual(BleProtocol.parseHello(f.dropFirst(3)), "7c0d995b-2c4")
        XCTAssertNil(BleProtocol.parseHello(Data([2]) + Data("abc".utf8)))  // unknown version
        XCTAssertNil(BleProtocol.parseHello(Data([1])))                     // empty id
        XCTAssertNil(BleProtocol.parseHello(Data([1, 10])))                 // not printable
    }

    func testPacketSurvivesAnyChunkSize() throws {
        let p = Packet(id: Packet.newId(), ts: 42, ttl: 16, cipher: Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) }))
        let stream = BleProtocol.hello(nodeId: "node-a") + BleProtocol.frame(BleProtocol.packetType, p.encode())
        for size in [1, 20, 182, 509] {
            var r = BleProtocol.Reader()
            let chunks = BleProtocol.chunks(stream, size: size)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= size })
            let got = try chunks.flatMap { try r.feed($0) }
            XCTAssertEqual(got.map(\.type), [BleProtocol.helloType, BleProtocol.packetType])
            XCTAssertEqual(got[1].payload, p.encode())
        }
    }

    func testChunkSizeNeverExceedsAttributeLimit() {
        XCTAssertEqual(BleProtocol.chunkSize(maxLength: 20), 20)
        XCTAssertEqual(BleProtocol.chunkSize(maxLength: 182), 182)
        XCTAssertEqual(BleProtocol.chunkSize(maxLength: 514), 512)
    }

    func testMalformedStreamsAreRejected() {
        var r1 = BleProtocol.Reader(); XCTAssertThrowsError(try r1.feed(Data([9, 0, 1, 0])))          // unknown type
        var r2 = BleProtocol.Reader(); XCTAssertThrowsError(try r2.feed(Data([2, 0xff, 0xff])))       // too long
        var r3 = BleProtocol.Reader(); XCTAssertThrowsError(try r3.feed(Data([1, 0, 0])))             // empty
        var r4 = BleProtocol.Reader(); XCTAssertEqual(try r4.feed(Data([2, 0])).count, 0)             // incomplete: wait
    }

    func testDuplicateLinkRuleIsSymmetric() {
        XCTAssertTrue(BleProtocol.keepMyCentralLink(myId: "259b6c4d-e98", remoteId: "7c0d995b-2c4"))
        XCTAssertFalse(BleProtocol.keepMyCentralLink(myId: "7c0d995b-2c4", remoteId: "259b6c4d-e98"))
        XCTAssertTrue(BleProtocol.keepMyCentralLink(myId: "abc", remoteId: "abcd"))
    }
}
