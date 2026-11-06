import XCTest
@testable import BlackoutCore

final class ReceiptsTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Vector cross-checked with Python's hashlib/hmac (spec/FORMAT.md, "Delivery receipts").
    func testReceiptKeyVector() {
        let group = GroupCrypto.deriveKey("test-group-1")
        XCTAssertEqual(hex(group), "5b3b419c3127c6562d34f9357179690746274ea9f6088385901e83d1d4055a9a")
        XCTAssertEqual(hex(GroupCrypto.deriveReceiptKey(group)), "496bfa142c33041abecd0fdb71763051e81c2fed0a55cbc1c0a7af8311d4a225")
    }

    /// Old apps try only the group and public keys: they must not be able to open a receipt, and the other way round.
    func testReceiptsOnlyOpenWithTheReceiptKey() throws {
        let group = GroupCrypto(code: "test-group-1"), receipts = group.receipts()
        let r = Packet(id: "00000000000000aa", ts: 1_000, ttl: 16,
                       cipher: try receipts.seal(id: "00000000000000aa", ts: 1_000, sender: "dev-b", name: "Bob", text: "0123456789abcdef"))
        XCTAssertNil(group.open(r))
        XCTAssertNil(GroupCrypto(code: GroupCrypto.publicCode).open(r))
        XCTAssertEqual(receipts.open(r)?.text, "0123456789abcdef")
        let m = Packet(id: "00000000000000bb", ts: 1_000, ttl: 16,
                       cipher: try group.seal(id: "00000000000000bb", ts: 1_000, sender: "dev-a", name: "Ann", text: "hi"))
        XCTAssertNil(receipts.open(m))
        XCTAssertNil(GroupCrypto(code: "other-group-9").receipts().open(r)) // another group's receipt key
    }

    func testReceiptIds() {
        let ids = ["0123456789abcdef", "fedcba9876543210"]
        XCTAssertEqual(Receipt.ids(in: Receipt.text(for: ids)), ids)
        XCTAssertEqual(Receipt.ids(in: "0123456789ABCDEF short 0123456789abcdeg  fedcba9876543210"), ["fedcba9876543210"])
        let many = (0..<450).map { String(format: "%016x", $0) }
        XCTAssertEqual(Receipt.batches(many).map(\.count), [200, 200, 50])
        XCTAssertEqual(Receipt.batches(many).flatMap { $0 }, many)
        XCTAssertTrue(Receipt.batches([]).isEmpty)
    }

    func testDeliveries() {
        func r(_ sender: String, _ name: String, _ ts: Int64, _ ids: [String]) -> Message {
            Message(id: "r\(sender)\(ts)", ts: ts, sender: sender, name: name, text: Receipt.text(for: ids))
        }
        let a = "000000000000000a", b = "000000000000000b"
        let d = Deliveries([
            r("lucia", "Lucia", 300, [a]),
            r("marco", "Marco", 200, [a, b]),
            r("marco", "Marco R.", 100, [a]),   // same reader again: counted once, earliest time, newest name
        ])
        XCTAssertEqual(d.readers[a]?.map(\.id), ["marco", "lucia"])
        XCTAssertEqual(d.readers[a]?.first?.ts, 100)
        XCTAssertEqual(d.readers[a]?.first?.name, "Marco R.")
        XCTAssertEqual(d.readers[b]?.map(\.name), ["Marco"])
        XCTAssertNil(d.readers["000000000000000c"])
    }
}
