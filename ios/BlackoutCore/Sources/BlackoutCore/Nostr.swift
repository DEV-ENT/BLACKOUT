import Foundation
import CryptoKit

/// DarkProof packets as Nostr events on public relays (spec/FORMAT.md, "Internet relays"). Same events as the Android
/// app's Nostr.kt. Signing (BIP-340 Schnorr) is passed in, so this file has no secp256k1 dependency.
public enum Nostr {
    public static let kind = 3871              // must match Android's Nostr.KIND
    public static let tagPrefix = "dp1-"
    public static let keepSeconds: Int64 = 7 * 24 * 3600

    public static func tag(_ mailbox: UInt16) -> String { tagPrefix + String(format: "%04x", mailbox) }

    /// NIP-01 string escaping, for computing event ids exactly as relays do.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// The event id: SHA-256 of [0, pubkey, created_at, kind, tags, content] serialized as NIP-01 says.
    public static func eventId(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
        let t = "[" + tags.map { "[" + $0.map(quote).joined(separator: ",") + "]" }.joined(separator: ",") + "]"
        let ser = "[0,\(quote(pubkey)),\(createdAt),\(kind),\(t),\(quote(content))]"
        return Hex.encode(Data(SHA256.hash(data: Data(ser.utf8))))
    }

    /// A signed event carrying one packet in its mailbox, findable by packet id, kept by relays for 7 days. `sign` makes a BIP-340 signature
    /// of the 32-byte id with the key whose x-only public key is `pubkey` (64 hex chars).
    public static func event(_ p: Packet, pubkey: String, now: Int64 = Int64(Date().timeIntervalSince1970),
                             sign: (Data) -> Data) -> [String: Any] {
        let tags = [["t", tag(Packet.mailbox(of: p.id))], ["x", p.id], ["expiration", String(now + keepSeconds)]]
        let content = p.encode().base64EncodedString()
        let id = eventId(pubkey: pubkey, createdAt: now, kind: kind, tags: tags, content: content)
        return ["id": id, "pubkey": pubkey, "created_at": now, "kind": kind, "tags": tags, "content": content,
                "sig": Hex.encode(sign(Hex.decode(id)))]
    }

    /// A NIP-56 report (kind 1984) of the event that carried a Public message.
    public static func report(eventId reported: String, author: String, pubkey: String,
                              now: Int64 = Int64(Date().timeIntervalSince1970), sign: (Data) -> Data) -> [String: Any] {
        let tags = [["e", reported, "other"], ["p", author]]
        let id = eventId(pubkey: pubkey, createdAt: now, kind: 1984, tags: tags, content: "")
        return ["id": id, "pubkey": pubkey, "created_at": now, "kind": 1984, "tags": tags, "content": "",
                "sig": Hex.encode(sign(Hex.decode(id)))]
    }

    public static func publish(_ event: [String: Any]) -> String { json(["EVENT", event]) }

    /// Subscribe to these mailboxes for the last 7 days.
    public static func subscribe(_ subId: String, mailboxes: [UInt16], now: Int64 = Int64(Date().timeIntervalSince1970)) -> String {
        json(["REQ", subId, ["kinds": [kind], "#t": mailboxes.map(tag), "since": now - keepSeconds, "limit": 500] as [String: Any]])
    }

    /// Asks which of these packets the relay already has (by the "x" tag), before passing them on.
    public static func have(_ subId: String, packetIds: [String]) -> String {
        json(["REQ", subId, ["kinds": [kind], "#x": packetIds, "limit": packetIds.count] as [String: Any]])
    }

    public static func close(_ subId: String) -> String { json(["CLOSE", subId]) }

    /// The reason, if this is a relay refusing an event (["OK", id, false, reason]); else nil.
    public static func refusal(_ text: String) -> String? {
        guard let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any], a.count >= 3,
              a[0] as? String == "OK", a[2] as? Bool == false else { return nil }
        return a.count > 3 ? a[3] as? String ?? "" : ""
    }

    /// A refusal that means "slow down": NIP-01's "rate-limited:" and "blocked:", and what relays really say
    /// ("rate limited", "banned: too many rate-limit violations").
    public static func isThrottle(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return ["rate", "banned", "blocked"].contains { r.hasPrefix($0) }
    }

    /// What a relay sent: a DarkProof packet with the event id and author (for reports), or nil for anything else.
    public struct Received { public let packet: Packet; public let eventId: String; public let pubkey: String }
    public static func received(_ text: String) -> Received? {
        guard let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any], a.count >= 3,
              a[0] as? String == "EVENT", let e = a[2] as? [String: Any], e["kind"] as? Int == kind,
              let content = e["content"] as? String, let raw = Data(base64Encoded: content), let p = Packet.decode(raw),
              let id = e["id"] as? String, let pub = e["pubkey"] as? String else { return nil }
        return Received(packet: p, eventId: id, pubkey: pub)
    }

    private static func json(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

/// "Connect through Tor" (spec/FORMAT.md, "Tor"): nothing goes to the relays until the Tor Project says this phone's
/// traffic leaves through Tor.
public enum TorCheck {
    public static let url = URL(string: "https://check.torproject.org/api/ip")!

    /// The answer looks like {"IsTor": true, "IP": …}.
    public static func isTor(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["IsTor"] as? Bool == true
    }
}
