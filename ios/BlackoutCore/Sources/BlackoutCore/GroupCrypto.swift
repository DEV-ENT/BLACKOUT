import Foundation
import CryptoKit
import CommonCrypto

public struct Message: Equatable, Sendable {
    public let id: String
    public let ts: Int64
    public let sender: String
    public let name: String
    public let text: String

    public init(id: String, ts: Int64, sender: String, name: String, text: String) {
        self.id = id; self.ts = ts; self.sender = sender; self.name = name; self.text = text
    }
}

public enum GroupCryptoError: Error { case fieldTooLong, badIv }

/// Group encryption: everyone who knows the group code can read and write; relays without it cannot. See spec/FORMAT.md.
public final class GroupCrypto: Sendable {
    private let key: SymmetricKey

    public init(code: String) { key = SymmetricKey(data: GroupCrypto.deriveKey(code)) }

    /// PBKDF2-HMAC-SHA256 over the UTF-8 bytes of the NFC-normalized group code.
    public static func deriveKey(_ code: String) -> Data {
        let pw = code.precomposedStringWithCanonicalMapping
        let salt = Array("blackout-mesh-v1".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let rc = pw.withCString { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p, pw.utf8.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 120_000, &out, out.count)
        }
        precondition(rc == kCCSuccess, "PBKDF2 failed: \(rc)")
        return Data(out)
    }

    /// Returns IV (12) + ciphertext + tag (16). [iv] is random in normal use; tests pass a fixed one.
    public func seal(id: String, ts: Int64, sender: String, name: String, text: String, iv: Data? = nil) throws -> Data {
        var plain = Data()
        for s in [sender, name, text] {
            let b = Data(s.utf8)
            guard b.count <= 0xFFFF else { throw GroupCryptoError.fieldTooLong }
            plain.append(UInt8(b.count >> 8)); plain.append(UInt8(b.count & 0xFF)); plain.append(b)
        }
        if let iv, iv.count != 12 { throw GroupCryptoError.badIv }
        let nonce = try iv.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: GroupCrypto.aad(id, ts))
        return box.combined! // never nil with a 12-byte nonce
    }

    /// nil if the packet was sealed with another code or was tampered with.
    public func open(_ p: Packet) -> Message? {
        guard let box = try? AES.GCM.SealedBox(combined: p.cipher),
              let plain = try? AES.GCM.open(box, using: key, authenticating: GroupCrypto.aad(p.id, p.ts)) else { return nil }
        var r = FieldReader(bytes: [UInt8](plain))
        guard let sender = r.next(), let name = r.next(), let text = r.next() else { return nil }
        return Message(id: p.id, ts: p.ts, sender: sender, name: name, text: text) // trailing bytes are ignored
    }

    private static func aad(_ id: String, _ ts: Int64) -> Data { Data("\(id)|\(ts)".utf8) }
}

/// Reads text fields: 2-byte big-endian length, then standard UTF-8.
private struct FieldReader {
    let bytes: [UInt8]
    var i = 0
    mutating func next() -> String? {
        guard i + 2 <= bytes.count else { return nil }
        let n = Int(bytes[i]) << 8 | Int(bytes[i + 1])
        guard i + 2 + n <= bytes.count else { return nil }
        defer { i += 2 + n }
        return String(decoding: bytes[(i + 2)..<(i + 2 + n)], as: UTF8.self)
    }
}
