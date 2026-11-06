import XCTest
import CryptoKit
@testable import BlackoutCore

/// The same vectors as Android's SchnorrTest: BIP-340 vector 0, plus one from @noble/curves 1.9.7 (independent code).
final class SchnorrTests: XCTestCase {
    private func sha(_ s: String) -> Data { Data(SHA256.hash(data: Data(s.utf8))) }

    func testBip340Vector0() {
        let sk = Hex.decode("0000000000000000000000000000000000000000000000000000000000000003")
        XCTAssertEqual(Hex.encode(Schnorr.publicKey(sk)), "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9")
        let sig = Schnorr.sign(secret: sk, message: Data(count: 32), aux: Data(count: 32))
        XCTAssertEqual(Hex.encode(sig), "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0")
        XCTAssertTrue(Schnorr.verify(pubkey: Schnorr.publicKey(sk), message: Data(count: 32), signature: sig))
    }

    func testMatchesNoble() {
        let sk = sha("darkproof-test-key"), msg = sha("hello nostr")
        XCTAssertEqual(Hex.encode(Schnorr.publicKey(sk)), "6dd447ac274cd77ed2bb1373b5571a181271583014de6a085437d709bc613bd5")
        XCTAssertEqual(Hex.encode(Schnorr.sign(secret: sk, message: msg, aux: Data(repeating: 1, count: 32))),
                       "625c3e45540c87f016e7cb88c28bb66d25b4d352e94a006af3f1489d5e9a0e896ee4890515b6c1e1e1026672d6a7ed6d3aa42de168101e8c036dd55222626e68")
    }

    func testRandomKeysSignAndVerify() {
        for i in 0..<3 {
            let key = Schnorr.newSecret(), pub = Schnorr.publicKey(key), msg = sha("m\(i)")
            var sig = Schnorr.sign(secret: key, message: msg)
            XCTAssertTrue(Schnorr.verify(pubkey: pub, message: msg, signature: sig))
            XCTAssertFalse(Schnorr.verify(pubkey: pub, message: sha("other"), signature: sig))
            sig[63] &+= 1
            XCTAssertFalse(Schnorr.verify(pubkey: pub, message: msg, signature: sig))
        }
    }

    func testNostrKey() {
        let k = NostrKey(secret: sha("darkproof-test-key"))
        XCTAssertEqual(k.pubkey, "6dd447ac274cd77ed2bb1373b5571a181271583014de6a085437d709bc613bd5")
        let id = sha("event")
        XCTAssertTrue(Schnorr.verify(pubkey: Hex.decode(k.pubkey), message: id, signature: k.sign(id)))
    }
}
