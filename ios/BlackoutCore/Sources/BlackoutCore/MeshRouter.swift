import Foundation

/// Flooding with deduplication and store-and-forward. No platform dependencies.
/// Same rules as the Android MeshRouter (spec/FORMAT.md, "Forwarding rules").
/// `send` is called while the router's lock is held, so it must hand the packet off without blocking.
public final class MeshRouter: @unchecked Sendable { // all state is guarded by `lock`
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

    /// Loads packets saved on disk at startup; they count as already seen.
    public func restore(_ all: [Packet]) { locked { for p in all.sorted(by: { $0.ts < $1.ts }) { seen.insert(p.id); keep(p) } } }

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

    public func receive(from: String, _ p: Packet) {
        locked {
            guard p.ts >= now() - retentionMs, seen.insert(p.id).inserted else { return }
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
