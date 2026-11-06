import Foundation
import CryptoKit
import CommonCrypto

public struct Message: Equatable, Sendable {
    public let id: String
    public let ts: Int64
    public let sender: String
    public let name: String
    public let text: String
    /// Sent on the Public channel (spec/FORMAT.md), readable by everyone.
    public let isPublic: Bool
    /// A small JPEG photo (spec/FORMAT.md, "Photos"), or nil.
    public let photo: Data?

    public init(id: String, ts: Int64, sender: String, name: String, text: String, isPublic: Bool = false, photo: Data? = nil) {
        self.id = id; self.ts = ts; self.sender = sender; self.name = name; self.text = text; self.isPublic = isPublic
        self.photo = photo
    }
}

public enum GroupCryptoError: Error { case fieldTooLong, badIv }

/// Photos ride in a 4th plaintext field that older readers skip (spec/FORMAT.md, "Photos").
public enum Photo {
    /// Type byte of a JPEG attachment.
    public static let jpeg: UInt8 = 0x01
    /// Most JPEG bytes in one message, so the whole packet stays under `Packet.maxCipher`.
    public static let maxBytes = 14_000
    /// The text older apps show for a photo without a caption.
    public static let placeholder = "📷 Photo"

    /// "📷 Photo" or "📷 <caption>".
    public static func text(caption: String) -> String {
        let c = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? placeholder : "📷 \(c)"
    }

    /// The caption of a photo message's text, or "" for none.
    public static func caption(_ text: String) -> String {
        guard text != placeholder else { return "" }
        return text.hasPrefix("📷 ") ? String(text.dropFirst(2)) : text
    }
}

/// Group encryption: everyone who knows the group code can read and write; relays without it cannot. See spec/FORMAT.md.
public final class GroupCrypto: Sendable {
    /// Code of the Public channel: everyone knows it, so anyone can read and post (spec/FORMAT.md).
    public static let publicCode = "blackout-public"
    private let key: SymmetricKey

    public init(code: String) { key = SymmetricKey(data: GroupCrypto.deriveKey(code)) }
    private init(key: SymmetricKey) { self.key = key }

    /// The group's delivery-receipt key (spec/FORMAT.md, "Delivery receipts"). Apps that don't know receipts can't
    /// open them with the group or public key, so they relay them without showing them.
    public func receipts() -> GroupCrypto {
        GroupCrypto(key: SymmetricKey(data: key.withUnsafeBytes { GroupCrypto.deriveReceiptKey(Data($0)) }))
    }

    /// HKDF-SHA256 of the group key, no salt, info "darkproof-receipt-v1", 32 bytes.
    public static func deriveReceiptKey(_ groupKey: Data) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: groupKey), info: Data("darkproof-receipt-v1".utf8),
                               outputByteCount: 32).withUnsafeBytes { Data($0) }
    }

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
    public func seal(id: String, ts: Int64, sender: String, name: String, text: String, photo: Data? = nil,
                     iv: Data? = nil) throws -> Data {
        var plain = Data()
        var fields = [sender, name, text].map { Data($0.utf8) }
        if let photo {
            guard photo.count <= Photo.maxBytes else { throw GroupCryptoError.fieldTooLong }
            fields.append(Data([Photo.jpeg]) + photo)
        }
        for b in fields {
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
        var photo: Data?
        if let a = r.nextBytes(), a.first == Photo.jpeg, a.count > 1, a.count - 1 <= Photo.maxBytes { photo = Data(a.dropFirst()) }
        return Message(id: p.id, ts: p.ts, sender: sender, name: name, text: text, photo: photo) // other bytes are ignored
    }

    private static func aad(_ id: String, _ ts: Int64) -> Data { Data("\(id)|\(ts)".utf8) }
}

/// Reads text fields: 2-byte big-endian length, then standard UTF-8.
private struct FieldReader {
    let bytes: [UInt8]
    var i = 0
    mutating func next() -> String? { nextBytes().map { String(decoding: $0, as: UTF8.self) } }

    mutating func nextBytes() -> [UInt8]? {
        guard i + 2 <= bytes.count else { return nil }
        let n = Int(bytes[i]) << 8 | Int(bytes[i + 1])
        guard i + 2 + n <= bytes.count else { return nil }
        defer { i += 2 + n }
        return Array(bytes[(i + 2)..<(i + 2 + n)])
    }
}
