#if DEBUG
import Foundation
import Network
import BlackoutCore

/// DEBUG BUILDS ONLY. TCP client for the Android app's LAN test listener (same framing: 4-byte length, then the
/// packet), so the iPhone app can be tested against the Android app on one computer. Packets go through the same
/// MeshRouter and GroupCrypto as the real links. It does NOT test Bluetooth or Apple peer-to-peer.
final class LanTestLink {
    static let prefix = "lan:"
    private static let retryDelay = 5.0
    private let q = DispatchQueue(label: "lan")
    private let router: MeshRouter
    private let onStatus: (String?) -> Void
    private var conn: NWConnection?
    private var linkId: String?
    private var gen = 0
    private var target = ""
    private var count = 0

    init(router: MeshRouter, onStatus: @escaping (String?) -> Void) { self.router = router; self.onStatus = onStatus }

    /// Keeps one link to host:port, reconnecting every 5 s, until stop() or another connect().
    func connect(host: String, port: UInt16) {
        q.async {
            self.teardown()
            self.target = "\(host):\(port)"
            self.dial(self.gen, host, port)
        }
    }

    func stop() { q.async { self.teardown(); self.target = ""; self.report() } }

    /// Ends the current link now (its cancel callback arrives later and is ignored as stale).
    private func teardown() {
        gen += 1
        conn?.cancel(); conn = nil
        if let id = linkId { linkId = nil; router.peerDown(id) }
    }

    func send(_ peer: String, _ p: Packet) {
        let b = p.encode()
        let frame = Data([UInt8(b.count >> 24 & 0xFF), UInt8(b.count >> 16 & 0xFF), UInt8(b.count >> 8 & 0xFF), UInt8(b.count & 0xFF)]) + b
        q.async {
            guard peer == self.linkId, let c = self.conn else { return }
            c.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func dial(_ g: Int, _ host: String, _ port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.count += 1
                let id = Self.prefix + String(self.count)
                self.linkId = id
                self.router.peerUp(id)
                self.report()
                self.readFrame(c, id)
            case .waiting: c.cancel() // e.g. connection refused: retry on our own schedule
            case .failed, .cancelled: self.closed(c, g, host, port)
            default: break
            }
        }
        c.start(queue: q)
        report()
    }

    private func readFrame(_ c: NWConnection, _ id: String) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, error in
            guard let self, let head, head.count == 4, error == nil else { c.cancel(); return }
            let n = head.reduce(0) { $0 << 8 | Int($1) }
            guard n > 0, n <= Packet.headerSize + Packet.maxCipher else { c.cancel(); return }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, error in
                guard let body, body.count == n, error == nil else { c.cancel(); return }
                if let p = Packet.decode(body) { self.router.receive(from: id, p) }
                self.readFrame(c, id)
            }
        }
    }

    private func closed(_ c: NWConnection, _ g: Int, _ host: String, _ port: UInt16) {
        guard c === conn else { return }
        conn = nil
        if let id = linkId { linkId = nil; router.peerDown(id) }
        report()
        guard g == gen else { return }
        q.asyncAfter(deadline: .now() + Self.retryDelay) { if g == self.gen { self.dial(g, host, port) } }
    }

    private func report() {
        if target.isEmpty { onStatus(nil); return }
        onStatus("LAN test: " + (linkId != nil ? "connected to \(target) · 1 link" : "connecting to \(target)"))
    }
}
#endif
