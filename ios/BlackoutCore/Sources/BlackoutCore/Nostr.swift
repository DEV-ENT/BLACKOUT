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

    /// The Public channel's mailbox (spec/FORMAT.md, "Mailboxes"): worldwide, so it is caught up one page only.
    public static let publicMailbox: UInt16 = 0x0794
    public static let page = 500                    // events per catch-up REQ
    public static let maxPages = 4                  // pages per group mailbox and relay link
    public static let sinceMarginSeconds: Int64 = 600 // catch-up starts 10 min before the last time seen: clocks differ

    /// New events for all these mailboxes, as they arrive. `since` 7 days back so events from phones with a slow clock
    /// still match; `limit` 1 because stored events come from the catch-up REQs.
    public static func live(_ subId: String, mailboxes: [UInt16], now: Int64 = Int64(Date().timeIntervalSince1970)) -> String {
        json(["REQ", subId, ["kinds": [kind], "#t": mailboxes.map(tag), "since": now - keepSeconds, "limit": 1] as [String: Any]])
    }

    /// One catch-up page of one mailbox: the newest `page` events since `since`, and not newer than `until` if set.
    public static func catchUp(_ subId: String, mailbox: UInt16, since: Int64, until: Int64?) -> String {
        var f: [String: Any] = ["kinds": [kind], "#t": [tag(mailbox)], "since": since, "limit": page]
        if let until { f["until"] = until }
        return json(["REQ", subId, f])
    }

    /// A relay's answer to an event: ["OK", event id, accepted, message]. "duplicate:" refusals count as accepted.
    public struct Ok: Sendable {
        public let eventId: String, accepted: Bool, reason: String
        public init(eventId: String, accepted: Bool, reason: String) { self.eventId = eventId; self.accepted = accepted; self.reason = reason }
    }
    public static func ok(_ text: String) -> Ok? {
        guard let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any], a.count >= 3, a[0] as? String == "OK",
              let id = a[1] as? String, let accepted = a[2] as? Bool else { return nil }
        let why = a.count > 3 ? a[3] as? String ?? "" : ""
        return Ok(eventId: id, accepted: accepted || why.lowercased().hasPrefix("duplicate"), reason: why)
    }

    /// The end of a subscription's stored events: ["EOSE", id] (complete) or ["CLOSED", id, reason] (not complete).
    public static func end(_ text: String) -> (subId: String, complete: Bool)? {
        guard let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any], a.count >= 2,
              let type = a[0] as? String, let id = a[1] as? String else { return nil }
        switch type {
        case "EOSE": return (id, true)
        case "CLOSED": return (id, false)
        default: return nil
        }
    }

    /// What makes two copies of a packet the same packet on the relays: its timestamp and cipher (ttl changes on every
    /// hop). First 16 bytes of SHA-256(ts as 8 bytes big-endian ‖ cipher), in hex.
    public static func digest(_ p: Packet) -> String {
        var h = SHA256()
        withUnsafeBytes(of: UInt64(bitPattern: p.ts).bigEndian) { h.update(bufferPointer: $0) }
        h.update(data: p.cipher)
        return Hex.encode(Data(h.finalize().prefix(16)))
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

    /// What a relay sent: a DarkProof packet with the event id and author (for reports) and its time and subscription
    /// (for catching up), or nil for anything else.
    public struct Received {
        public let packet: Packet; public let eventId: String; public let pubkey: String
        public let createdAt: Int64; public let subId: String
    }
    public static func received(_ text: String) -> Received? {
        guard let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any], a.count >= 3,
              a[0] as? String == "EVENT", let e = a[2] as? [String: Any], e["kind"] as? Int == kind,
              let content = e["content"] as? String, let raw = Data(base64Encoded: content), let p = Packet.decode(raw),
              let id = e["id"] as? String, let pub = e["pubkey"] as? String else { return nil }
        return Received(packet: p, eventId: id, pubkey: pub, createdAt: (e["created_at"] as? NSNumber)?.int64Value ?? 0,
                        subId: a[1] as? String ?? "")
    }

    private static func json(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

/// Where the catch-up of each relay and mailbox starts next time (spec/FORMAT.md, "Subscribe"), in seconds, saved on
/// the phone as "<relay url>|<mailbox hex>=<seconds>,…". Same format as Android's RelaySince. Not thread-safe.
public final class RelaySince {
    public static let max = 400
    private var at: [String: Int64] = [:]
    private var order: [String] = []   // oldest change first
    /// True when something moved since `save()`.
    public private(set) var changed = false

    public init(_ saved: String = "") {
        for e in saved.split(separator: ",") {
            guard let i = e.lastIndex(of: "="), let v = Int64(e[e.index(after: i)...]) else { continue }
            let k = String(e[..<i]); if at[k] == nil { order.append(k) }; at[k] = v
        }
    }
    public func get(_ relay: String, _ mailbox: UInt16) -> Int64? { at[key(relay, mailbox)] }
    /// Moves the start forward to `t`; never back.
    public func advance(_ relay: String, _ mailbox: UInt16, to t: Int64) {
        let k = key(relay, mailbox)
        if let old = at[k], old >= t { return }
        order.removeAll { $0 == k }; order.append(k); at[k] = t; changed = true
        while order.count > Self.max { at[order.removeFirst()] = nil }
    }
    public func save() -> String { changed = false; return order.map { "\($0)=\(at[$0]!)" }.joined(separator: ",") }
    private func key(_ relay: String, _ mailbox: UInt16) -> String { relay + "|" + String(format: "%04x", mailbox) }
}

/// Catch-up on one relay link (spec/FORMAT.md, "Subscribe"): one REQ per mailbox, one mailbox at a time, in the order
/// given (groups before the Public channel), so a busy mailbox never crowds out another. A page that comes back full
/// is followed by an older one (`until`), up to `Nostr.maxPages` for a group and one for the Public channel. A mailbox
/// whose catch-up ends with EOSE starts next time where this one started; a refused one (CLOSED) or one with no answer
/// is left for the next link. Times in seconds. Not thread-safe. Same as Android's CatchUp.
public final class CatchUp {
    public struct Req: Sendable {
        public let subId: String, mailbox: UInt16, since: Int64, until: Int64?
        public var text: String { Nostr.catchUp(subId, mailbox: mailbox, since: since, until: until) }
    }
    private let relay: String
    private let since: RelaySince
    private let prefix: String
    private var todo: [UInt16] = []
    /// Mailboxes caught up on this link: their live events move the saved start forward.
    public private(set) var done = Set<UInt16>()
    /// The REQ waiting for its EOSE, and when it was sent.
    public private(set) var current: Req?
    public private(set) var sentAt: Int64 = 0
    private var startedAt: Int64 = 0
    private var pages = 0, count = 0, oldest = Int64.max, n = 0

    public init(relay: String, since: RelaySince, prefix: String = "cu") { self.relay = relay; self.since = since; self.prefix = prefix }

    public func add(_ mailboxes: [UInt16]) {
        for m in mailboxes where !done.contains(m) && !todo.contains(m) && m != current?.mailbox { todo.append(m) }
    }

    /// The next REQ to send, if none is waiting for its answer.
    public func next(now: Int64) -> Req? {
        guard current == nil, !todo.isEmpty else { return nil }
        let m = todo.removeFirst()
        startedAt = now; pages = 0
        return page(m, from: Swift.max(now - Nostr.keepSeconds, (since.get(relay, m) ?? 0) - Nostr.sinceMarginSeconds), until: nil, now: now)
    }

    public func event(_ subId: String, createdAt: Int64) {
        if current?.subId == subId { count += 1; oldest = Swift.min(oldest, createdAt) }
    }

    /// `subId` ended: EOSE (`complete`) or CLOSED / no answer. Returns the next REQ: an older page, or the next mailbox.
    public func end(_ subId: String, complete: Bool, now: Int64) -> Req? {
        guard let c = current, c.subId == subId else { return nil }
        current = nil
        if complete {
            let max = c.mailbox == Nostr.publicMailbox ? 1 : Nostr.maxPages
            if count >= Nostr.page && pages < max { return page(c.mailbox, from: c.since, until: oldest == c.until ? oldest - 1 : oldest, now: now) }
            done.insert(c.mailbox)
            since.advance(relay, c.mailbox, to: startedAt)
        }
        return next(now: now)
    }

    /// A live event of `mailbox` made at `createdAt`: once caught up, the saved start follows it (never past now).
    public func live(_ mailbox: UInt16, createdAt: Int64, now: Int64) {
        if done.contains(mailbox) { since.advance(relay, mailbox, to: Swift.min(createdAt, now)) }
    }

    private func page(_ m: UInt16, from: Int64, until: Int64?, now: Int64) -> Req {
        count = 0; oldest = .max; pages += 1; sentAt = now; n += 1
        let r = Req(subId: prefix + String(n), mailbox: m, since: from, until: until)
        current = r
        return r
    }
}

/// What this phone still has to post to the relays (spec/FORMAT.md, "Publish"), and what they confirmed. Own packets
/// go first, newest first; anyone else's are first looked up with `#x` and posted only if no relay returned the same
/// packet (`Nostr.digest`). A packet counts as sent only once a relay answered ["OK", <event id>, true, …]; if every
/// relay it went to refused it, or none accepted it within 30 s, it is queued again, up to 3 tries. The queues keep the
/// newest packets when full. Not thread-safe. Same rules as Android's RelayOutbox.
public final class RelayOutbox {
    public static let ownMax = 500, candidatesMax = 5_000, missingMax = 2_000
    public static let sentMax = 3_000, onRelaysMax = 5_000, flightsMax = 300
    public static let freshMs: Int64 = 120_000   // own packets younger than this go up without asking first
    public static let answerMs: Int64 = 30_000   // how long a post waits for a relay to accept it
    public static let tries = 3
    /// A bridged packet waits up to this long, at random, before the relays are asked about it: phones that got it at
    /// the same moment then don't all find it missing and all post it. Own packets never wait.
    public static let jitterMs: Int64 = 30_000

    private final class Flight {
        let p: Packet, fromOwn: Bool, relays: Set<String>, at: Int64
        var refused = Set<String>(), over = false
        init(_ p: Packet, _ fromOwn: Bool, _ relays: Set<String>, _ at: Int64) { self.p = p; self.fromOwn = fromOwn; self.relays = relays; self.at = at }
    }
    private let now: () -> Int64
    private let jitter: () -> Int64
    private var due: [String: Int64] = [:]         // candidate id -> when the relays may be asked about it
    private var own: [String: Packet] = [:]        // written on this phone: up first, newest first
    private var candidates: [String: Packet] = [:] // anyone else's, not yet looked up
    private var missing: [String: Packet] = [:]    // looked up: no relay has them, so this phone posts them
    private var flying = Set<String>()             // posted, waiting for an answer
    private var sent: RecentIds                    // on the relays already
    private var onRelays: [String: String] = [:], onRelaysOrder: [String] = [] // packet id -> digest of a relay's copy
    private var flights: [String: Flight] = [:], flightOrder: [String] = []     // event id -> post; ended ones stay a while
    private var triesOf: [String: Int] = [:]
    /// True when the sent list changed since `sentList()`: the caller saves it.
    public private(set) var changed = false

    public init(sent: [String] = [], now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                jitter: @escaping () -> Int64 = { Int64.random(in: 0..<RelayOutbox.jitterMs) }) {
        self.sent = RecentIds(max: Self.sentMax, sent); self.now = now; self.jitter = jitter
    }

    /// The router offers a packet. `mine`: written on this phone (a message or a receipt).
    public func offer(_ p: Packet, mine: Bool) {
        let t = now()
        guard !sent.contains(p.id), !flying.contains(p.id), onRelays[p.id] != Nostr.digest(p),
              p.ts >= t - Nostr.keepSeconds * 1000 else { return }
        triesOf[p.id] = nil
        if mine && p.ts > t - Self.freshMs { put(&own, p, Self.ownMax) }
        else if missing[p.id] == nil, own[p.id] == nil {
            put(&candidates, p, Self.candidatesMax)
            if due[p.id] == nil { due[p.id] = t + jitter() }
            if due.count > Self.candidatesMax { due = due.filter { candidates[$0.key] != nil } }
        }
    }

    /// The next packet to post: the newest own one, else (if `bridged`) the newest no relay had. Too old ones are skipped.
    public func next(bridged: Bool) -> (packet: Packet, fromOwn: Bool)? {
        if let p = Self.newest(&own, cut: now() - Nostr.keepSeconds * 1000) { return (p, true) }
        if bridged, let p = Self.newest(&missing, cut: now() - Nostr.keepSeconds * 1000) { return (p, false) }
        return nil
    }
    private static func newest(_ q: inout [String: Packet], cut: Int64) -> Packet? {
        q = q.filter { $0.value.ts >= cut } // checked again right before posting
        guard let p = q.values.max(by: { $0.ts < $1.ts }) else { return nil }
        q[p.id] = nil
        return p
    }

    /// `p` went out as event `eventId` to `relays`.
    public func posted(eventId: String, _ p: Packet, fromOwn: Bool, relays: Set<String>) {
        flights[eventId] = Flight(p, fromOwn, relays, now()); flightOrder.append(eventId); flying.insert(p.id)
        while flightOrder.count > Self.flightsMax {
            if let f = flights.removeValue(forKey: flightOrder.removeFirst()), !f.over { flying.remove(f.p.id) }
        }
    }

    /// A relay answered an event. Returns the packet id if this made it sent (the caller reports it), else nil.
    public func answer(relay: String, _ ok: Nostr.Ok) -> String? {
        guard let f = flights[ok.eventId] else { return nil }
        if ok.accepted {
            flights[ok.eventId] = nil; flightOrder.removeAll { $0 == ok.eventId }; flying.remove(f.p.id)
            return markSent(f.p.id) ? f.p.id : nil
        }
        f.refused.insert(relay)
        if !f.over && f.refused.isSuperset(of: f.relays) { fail(f) }
        return nil
    }

    /// Posts that no relay accepted within 30 s are queued again.
    public func expire() {
        let t = now()
        for id in flightOrder { if let f = flights[id], !f.over, t - f.at >= Self.answerMs { fail(f) } }
    }

    private func fail(_ f: Flight) {
        f.over = true; flying.remove(f.p.id)
        guard !sent.contains(f.p.id) else { return }
        let n = (triesOf[f.p.id] ?? 0) + 1; triesOf[f.p.id] = n
        if triesOf.count > Self.missingMax { triesOf = [f.p.id: n] } // rarely: forget old counts
        guard n < Self.tries else { return } // until the router offers it again (next link to the relays)
        if f.fromOwn { put(&own, f.p, Self.ownMax) } else { put(&missing, f.p, Self.missingMax) }
    }

    /// A relay sent this packet. Returns its id if a queued copy is the same packet, which is now sent; else nil.
    public func fromRelay(_ p: Packet) -> String? {
        let d = Nostr.digest(p)
        if onRelays[p.id] == nil { onRelaysOrder.append(p.id) }
        onRelays[p.id] = d
        while onRelaysOrder.count > Self.onRelaysMax { onRelays[onRelaysOrder.removeFirst()] = nil }
        let queued = own[p.id] ?? candidates[p.id] ?? missing[p.id] ?? flights.values.first { $0.p.id == p.id && !$0.over }?.p
        guard let q = queued, Nostr.digest(q) == d, markSent(p.id) else { return nil }
        return p.id
    }

    /// Up to `n` of the newest packets to look up on the relays (`#x`).
    public func toCheck(_ n: Int) -> [Packet] {
        let t = now()
        let batch = Array(candidates.values.filter { (due[$0.id] ?? 0) <= t }.sorted { $0.ts > $1.ts }.prefix(n))
        batch.forEach { candidates[$0.id] = nil; due[$0.id] = nil }
        return batch
    }

    /// After the lookup: packets a relay returned with the same contents are sent (their ids returned), the rest get posted.
    public func checked(_ batch: [Packet]) -> [String] {
        var found: [String] = []
        for p in batch {
            if onRelays[p.id] == Nostr.digest(p) { if markSent(p.id) { found.append(p.id) } }
            else if !sent.contains(p.id), !flying.contains(p.id) { put(&missing, p, Self.missingMax) }
        }
        return found
    }

    public func sentList() -> [String] { changed = false; return sent.list }
    public func isSent(_ id: String) -> Bool { sent.contains(id) }
    public var queued: Int { own.count + candidates.count + missing.count }

    private func markSent(_ id: String) -> Bool {
        guard sent.add(id) else { return false }
        changed = true; own[id] = nil; candidates[id] = nil; missing[id] = nil
        return true
    }

    /// Full queue: the oldest packet makes room if the new one is newer.
    private func put(_ q: inout [String: Packet], _ p: Packet, _ max: Int) {
        if q.count >= max, q[p.id] == nil {
            guard let oldest = q.values.min(by: { $0.ts < $1.ts }), oldest.ts < p.ts else { return }
            q[oldest.id] = nil
        }
        q[p.id] = p
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
