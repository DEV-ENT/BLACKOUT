import XCTest
@testable import BlackoutCore

final class PhotoTests: XCTestCase {
    let group = GroupCrypto(code: "test-group-1")
    let iv = Data(repeating: 7, count: 12)
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data((0..<9_000).map { UInt8($0 % 251) }) + Data([0xFF, 0xD9])

    func testPhotoRoundTrip() throws {
        let c = try group.seal(id: "00000000000000aa", ts: 5, sender: "dev-a", name: "Ann", text: Photo.text(caption: "Bridge is out"), photo: jpeg)
        let m = group.open(Packet(id: "00000000000000aa", ts: 5, ttl: 16, cipher: c))
        XCTAssertEqual(m?.photo, jpeg)
        XCTAssertEqual(m?.text, "📷 Bridge is out")
        XCTAssertEqual(Photo.caption(m?.text ?? ""), "Bridge is out")
        let plain = group.open(Packet(id: "00000000000000bb", ts: 5, ttl: 16,
                                      cipher: try group.seal(id: "00000000000000bb", ts: 5, sender: "dev-a", name: "Ann", text: "hi")))
        XCTAssertNil(plain?.photo)
    }

    /// Older readers parse three fields and stop. AES-GCM encrypts like a stream, so with the same IV the message
    /// without a photo is a byte-for-byte prefix of the one with it: old apps see exactly the same three fields.
    func testOlderReadersSeeTheSameThreeFields() throws {
        let without = try group.seal(id: "00000000000000cc", ts: 9, sender: "dev-a", name: "Ann", text: Photo.placeholder, iv: iv)
        let with = try group.seal(id: "00000000000000cc", ts: 9, sender: "dev-a", name: "Ann", text: Photo.placeholder, photo: jpeg, iv: iv)
        let body = without.count - 16 // without the 16-byte tag
        XCTAssertEqual(with.prefix(body), without.prefix(body))
        XCTAssertGreaterThan(with.count, without.count + jpeg.count)
    }

    func testLimits() throws {
        XCTAssertThrowsError(try group.seal(id: "00000000000000dd", ts: 1, sender: "d", name: "n", text: "t",
                                            photo: Data(count: Photo.maxBytes + 1)))
        // Biggest photo, a long name and a long emoji caption still fit one packet.
        let c = try group.seal(id: "00000000000000ee", ts: 1, sender: "7c0d995b-2c4", name: String(repeating: "🙂", count: 20),
                               text: Photo.text(caption: String(repeating: "🙂", count: 200)), photo: Data(count: Photo.maxBytes))
        XCTAssertLessThanOrEqual(c.count, Packet.maxCipher)
        XCTAssertNotNil(Packet.decode(Packet(id: "00000000000000ee", ts: 1, ttl: 16, cipher: c).encode()))
    }

    func testCaptions() {
        XCTAssertEqual(Photo.text(caption: "  "), "📷 Photo")
        XCTAssertEqual(Photo.caption("📷 Photo"), "")
        XCTAssertEqual(Photo.caption("📷 Water here"), "Water here")
    }
}
