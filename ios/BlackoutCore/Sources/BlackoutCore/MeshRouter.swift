import Foundation

/// Flooding with deduplication and store-and-forward. No platform dependencies.
/// Same rules as the Android MeshRouter (spec/FORMAT.md, "Forwarding rules").
/// `send` is called while the router's lock is held, so it must hand the packet off without blocking.
public final class MeshRouter: @unchecked Sendable { // all state is guarded by `lock`
    /// Hops a new packet gets. A received packet with more (v0.4 decoding allows up to 64) is lowered to this.
    public static let maxTtl = 16
    /// Packets dated more than this ahead of this phone's clock are dropped (spec/FORMAT.md, "Forwarding rules").
    public static let maxFutureMs: Int64 = 10 * 60_000
    public static func inFuture(_ ts: Int64, now: Int64) -> Bool { ts > now + maxFutureMs }
    public static func clamp(_ p: Packet) -> Packet { p.ttl > maxTtl ? p.withTtl(maxTtl) : p }

    private let send: (_ peer: String, _ p: Packet) -> Void
    private let deliver: (Packet) -> Void
    private let now: () -> Int64
    private let retentionMs: Int64
    private let maxStored: Int
    private let lock = NSRecursiveLock() // re-entrant, like Kotlin's @Synchronized
    private var peers: [String] = []     // insertion-ordered set
    private var seen = Set<String>()
    private var order: [String] = []     // stored ids, oldest first
    private var stored: [String: Packet] = [:]

    public init(send: @escaping (_ peer: String, _ p: Packet) -> Void,
                deliver: @escaping (Packet) -> Void,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                retentionMs: Int64 = 7 * 24 * 3_600_000,
                maxStored: Int = 500) {
        self.send = send; self.deliver = deliver; self.now = now
        self.retentionMs = retentionMs; self.maxStored = maxStored
    }

    public var peerCount: Int { locked { peers.count } }

    /// After a restart: `all` is passed on again; `seenIds` are packets already handled, so they aren't shown twice.
    /// Packets dated in the future are left out. Peers already linked get the packets that are new to the router.
    public func restore(_ all: [Packet], seenIds: Set<String> = []) {
        locked {
            seen.formUnion(seenIds)
            let t = now()
            let fresh = all.filter { !Self.inFuture($0.ts, now: t) && stored[$0.id] == nil }.sorted { $0.ts < $1.ts }.map(Self.clamp)
            for p in fresh { seen.insert(p.id); keep(p) }
            for p in fresh where stored[p.id] != nil { for peer in peers { forward(peer, p) } }
        }
    }

    /// Sends a message written on this device.
    public func publish(_ p: Packet) { locked { seen.insert(p.id); keep(p); for peer in peers { forward(peer, p) } } }

    public func peerDown(_ peer: String) { locked { peers.removeAll { $0 == peer } } }

    /// A new neighbor gets everything still stored.
    public func peerUp(_ peer: String) {
        locked {
            if !peers.contains(peer) { peers.append(peer) }
            prune()
            for id in order { if let p = stored[id] { forward(peer, p) } }
        }
    }

    /// Packets older than 7 days or more than 10 minutes in the future are dropped; ttl above 16 is lowered to 16.
    public func receive(from: String, _ packet: Packet) {
        locked {
            let t = now()
            guard packet.ts >= t - retentionMs, !Self.inFuture(packet.ts, now: t), seen.insert(packet.id).inserted else { return }
            let p = Self.clamp(packet)
            keep(p); deliver(p)
            for peer in peers where peer != from { forward(peer, p) }
        }
    }

    private func forward(_ peer: String, _ p: Packet) { if p.ttl > 1 { send(peer, p.withTtl(p.ttl - 1)) } }
    private func keep(_ p: Packet) {
        if stored[p.id] == nil { order.append(p.id) }
        stored[p.id] = p
        prune()
    }
    private func prune() {
        let cut = now() - retentionMs
        order.removeAll { id in
            guard let p = stored[id], p.ts >= cut else { stored[id] = nil; return true }
            return false
        }
        while order.count > maxStored { stored[order.removeFirst()] = nil }
    }
    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
}

/// Which stored packets to remove when the store is over its cap (spec/FORMAT.md, "Storage"): first packets no saved
/// group can read, oldest first, then the oldest Public messages, and only then the oldest messages and receipts of
/// the saved groups. Same rules as the Android StoreCap.
public enum StoreCap {
    public static let maxBytes = 40 * 1024 * 1024
    public static let maxCount = 20_000
    /// In the order they go: `.unreadable` first, `.group` last.
    public enum Kind: Int, Sendable { case unreadable, isPublic, group }
    /// `size`: the encoded packet's length.
    public struct Entry: Sendable {
        public let id: String, ts: Int64, size: Int, kind: Kind
        public init(id: String, ts: Int64, size: Int, kind: Kind) { self.id = id; self.ts = ts; self.size = size; self.kind = kind }
    }

    /// Ids to remove so that at most `maxBytes` and `maxCount` remain; empty if the store fits.
    public static func overflow(_ entries: some Collection<Entry>, maxBytes: Int = maxBytes, maxCount: Int = maxCount) -> [String] {
        var bytes = entries.reduce(0) { $0 + $1.size }, count = entries.count
        guard bytes > maxBytes || count > maxCount else { return [] }
        var out: [String] = []
        for e in entries.sorted(by: { ($0.kind.rawValue, $0.ts, $0.id) < ($1.kind.rawValue, $1.ts, $1.id) }) {
            if bytes <= maxBytes && count <= maxCount { break }
            out.append(e.id); bytes -= e.size; count -= 1
        }
        return out
    }
}

/// Two links between the same two phones (spec/FORMAT.md, "Wi-Fi networks"): which one stays. When both phones dialed
/// each other at about the same time (the older link is less than 10 s old), the link dialed by the smaller node id
/// stays, so both phones keep the same one. Otherwise, or when the same phone dialed both, the new link replaces the
/// old one: after a restart the old one may be dead without either side knowing. Same as the Android DuplicateLinks.
public enum DuplicateLinks {
    public static let sameTimeMs: Int64 = 10_000
    public static func keepNew(myId: String, remoteId: String, newDialedByMe: Bool, oldDialedByMe: Bool, oldAgeMs: Int64) -> Bool {
        if newDialedByMe == oldDialedByMe || oldAgeMs >= sameTimeMs { return true }
        let meSmaller = BleProtocol.keepMyCentralLink(myId: myId, remoteId: remoteId) // byte comparison of the node ids
        return newDialedByMe ? meSmaller : !meSmaller
    }
}

/// An ordered set of ids that forgets the oldest beyond `max`, for lists saved on the phone. Not thread-safe.
public struct RecentIds: Sendable {
    private let max: Int
    private var order: [String] = []
    private var set = Set<String>()
    public init(max: Int, _ initial: [String] = []) { self.max = max; initial.forEach { add($0) } }
    /// True if `id` is new.
    @discardableResult public mutating func add(_ id: String) -> Bool {
        guard set.insert(id).inserted else { return false }
        order.append(id)
        if order.count > max { let n = order.count - max; order.prefix(n).forEach { set.remove($0) }; order.removeFirst(n) }
        return true
    }
    public func contains(_ id: String) -> Bool { set.contains(id) }
    public var count: Int { order.count }
    public var list: [String] { order }
}
