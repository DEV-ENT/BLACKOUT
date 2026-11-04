import XCTest
@testable import BlackoutCore

/// Checks the Swift implementation byte-for-byte against spec/test-vectors.txt, which the Android app also checks.
final class VectorsTests: XCTestCase {
    static let vectors: [[String: String]] = {
        // .../Blackout/ios/BlackoutCore/Tests/BlackoutCoreTests/VectorsTests.swift -> .../Blackout/spec/test-vectors.txt
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let text = try! String(contentsOf: url.appendingPathComponent("spec/test-vectors.txt"), encoding: .utf8)
        return text.components(separatedBy: "\n\n").map { block in
            var v: [String: String] = [:]
            for line in block.split(separator: "\n") where !line.hasPrefix("#") {
                if let r = line.range(of: ": ") { v[String(line[..<r.lowerBound])] = String(line[r.upperBound...]) }
            }
            return v
        }.filter { !$0.isEmpty }
    }()
    private func of(_ kind: String) -> [[String: String]] { Self.vectors.filter { $0["kind"] == kind } }
    private func code(_ v: [String: String]) -> String {
        v["code"] ?? String(decoding: Hex.decode(v["code_hex"]!), as: UTF8.self)
    }

    func testVectorFileHasAllKinds() {
        XCTAssertEqual(of("kdf").count, 3); XCTAssertEqual(of("seal").count, 2)
    }

    func testKeyDerivationMatches() {
        for v in of("kdf") { XCTAssertEqual(Hex.encode(GroupCrypto.deriveKey(code(v))), v["key"], "\(v)") }
    }

    func testSealProducesIdenticalPacket() throws {
        for v in of("seal") {
            let id = v["id"]!, ts = Int64(v["ts"]!)!
            let cipher = try GroupCrypto(code: code(v)).seal(id: id, ts: ts, sender: v["sender"]!, name: v["name"]!,
                                                             text: v["text"]!, iv: Hex.decode(v["iv"]!))
            XCTAssertEqual(Hex.encode(Packet(id: id, ts: ts, ttl: Int(v["ttl"]!)!, cipher: cipher).encode()), v["packet"], v["name"]!)
        }
    }

    func testVectorPacketsDecodeAndOpen() {
        for v in of("seal") {
            let p = Packet.decode(Hex.decode(v["packet"]!))!
            XCTAssertEqual(p.id, v["id"]); XCTAssertEqual(p.ts, Int64(v["ts"]!)); XCTAssertEqual(p.ttl, Int(v["ttl"]!))
            let m = GroupCrypto(code: code(v)).open(p)
            XCTAssertEqual(m?.sender, v["sender"]); XCTAssertEqual(m?.name, v["name"]); XCTAssertEqual(m?.text, v["text"])
            XCTAssertNil(GroupCrypto(code: "wrong-code").open(p))
        }
    }

    func testOldV02PacketsAreRejected() {
        var raw = Hex.decode(of("seal")[0]["packet"]!); raw[0] = 0xB1
        XCTAssertNil(Packet.decode(raw))
    }
}
