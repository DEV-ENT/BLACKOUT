import Foundation
import Network
import UIKit
import BlackoutCore

/// Links to DarkProof phones (iPhone or Android) on the same Wi-Fi network over TCP, found with Bonjour
/// (spec/FORMAT.md, "Wi-Fi networks"): a router with no internet, a hotspot, a community network or a rooftop link.
/// Only the phone with the smaller node id connects to a discovered phone; an address the user typed is always dialed.
/// The listener and the Bonjour browser start again after any failure, and when the app comes back to the foreground
/// (iOS may stop them while the app is suspended): the browser always, the listener unless it is still ready.
final class WifiLink {
    static let prefix = "wifi:"
    static let serviceType = "_darkproof._tcp"
    static let port: UInt16 = 7777
    static let maxFrame = 16_064
    static let maxLinks = 32
    private static let hello = Data("DPW1".utf8)
    private static let retryDelay = 5.0
    private static let helloWait = 10.0   // the other side's HELLO must come within this

    private let q = DispatchQueue(label: "wifi")
    private let nodeId: String
    private let router: MeshRouter
    private let onStatus: (String?) -> Void
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [String: (node: String, conn: NWConnection, dialed: Bool, since: Date)] = [:] // router peer id -> link
    private var byNode: [String: String] = [:]                              // node id -> router peer id
    private var found: [String: NWEndpoint] = [:]                           // discovered node id -> endpoint
    private var dialing = Set<String>()
    private var count = 0
    private var running = false
    private var manualTarget: (host: String, port: UInt16)?
    private var manualConn: NWConnection?
    private var manualGen = 0
    private var manualNode: String?        // who answered at the typed address last time
    private var note = ""
    private var listenGen = 0, browseGen = 0 // ignore state updates of a listener or browser already replaced
    private var listenRetry = 2.0, browseRetry = 2.0

    init(nodeId: String, router: MeshRouter, onStatus: @escaping (String?) -> Void) {
        self.nodeId = nodeId; self.router = router; self.onStatus = onStatus
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.q.async {
                guard self.running else { return }
                // A listener that is still ready keeps its port (7777 would be busy for a moment after closing it).
                if let l = self.listener, case .ready = l.state {} else { self.listen(on: Self.port) }
                self.browse()
            }
        }
    }

    var nodes: Set<String> { q.sync { Set(byNode.keys) } }
    var listeningPort: UInt16? { q.sync { listener?.port?.rawValue } }
    var isOn: Bool { q.sync { running } }
    var manualAddress: String? { q.sync { manualTarget.map { "\($0.host):\($0.port)" } } }

    func start() {
        q.async {
            guard !self.running else { return }
            self.running = true
            self.listen(on: Self.port)
            self.browse()
            self.retryLoop()
            self.report()
        }
    }

    func stop() {
        q.async {
            self.running = false
            self.listenGen += 1; self.browseGen += 1
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            self.found = [:]
            self.stopManualLocked()
            for (_, l) in self.links { l.conn.cancel() }
            self.report()
        }
    }

    /// Keeps a link to an address the user typed, redialing every 5 s, until `stopManual()` or another address.
    func connect(host: String, port: UInt16) {
        q.async {
            self.stopManualLocked()
            self.manualTarget = (host, port); self.manualNode = nil
            self.dialManual(self.manualGen, host, port)
        }
    }

    func stopManual() { q.async { self.stopManualLocked(); self.report() } }

    private func stopManualLocked() {
        manualGen += 1; manualTarget = nil
        manualConn?.cancel(); manualConn = nil
    }

    /// Called by the router, possibly while it holds its lock: the write happens on this link's queue.
    func send(_ peer: String, _ p: Packet) {
        let b = p.encode()
        q.async { self.links[peer]?.conn.send(content: Self.frame(b), completion: .contentProcessed { _ in }) }
    }

    // MARK: - Listening and discovery

    /// (Re)starts the listener on 7777, or on any free port if 7777 is taken. After any failure it starts again,
    /// later and later (2 s, then up to 30 s).
    private func listen(on port: UInt16) {
        guard running else { return }
        listenGen += 1
        let gen = listenGen
        listener?.cancel(); listener = nil
        let l: NWListener
        do { l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) }
        catch {
            guard port != 0, let any = try? NWListener(using: .tcp) else { note = "can't listen"; relisten(gen); return }
            l = any
        }
        l.service = NWListener.Service(name: nodeId, type: Self.serviceType)
        l.newConnectionHandler = { [weak self] c in self?.run(c, dialed: false) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.listenGen else { return }
            switch state {
            case .ready: self.listenRetry = 2; if self.note == "can't listen" { self.note = "" }
            case .failed:
                l.cancel(); self.listener = nil
                if port == Self.port { self.listen(on: 0) } else { self.relisten(gen) } // 7777 taken: any free port
            default: break
            }
        }
        l.start(queue: q)
        listener = l
    }

    private func relisten(_ gen: Int) {
        let wait = listenRetry; listenRetry = min(listenRetry * 2, 30)
        q.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.running, gen == self.listenGen else { return }
            self.listen(on: Self.port)
        }
    }

    /// (Re)starts the Bonjour browser; after a failure it starts again, later and later (2 s, then up to 30 s).
    private func browse() {
        guard running else { return }
        browseGen += 1
        let gen = browseGen
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, gen == self.browseGen else { return }
            self.discovered(results)
        }
        b.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.browseGen else { return }
            switch state {
            case .ready: self.browseRetry = 2; self.setDenied(false)
            case .waiting(let e): // the user refused Local Network: Bonjour waits for ever
                if case .dns(let code) = e, code == -65570 { self.setDenied(true) } // kDNSServiceErr_PolicyDenied
            case .failed:
                b.cancel(); self.browser = nil
                let wait = self.browseRetry; self.browseRetry = min(self.browseRetry * 2, 30)
                self.q.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self, self.running, gen == self.browseGen else { return }
                    self.browse()
                }
            default: break
            }
        }
        b.start(queue: q)
        browser = b
    }

    private func discovered(_ results: Set<NWBrowser.Result>) {
        var now: [String: NWEndpoint] = [:]
        for r in results {
            if case let .service(name, _, _, _) = r.endpoint, name != nodeId { now[name] = r.endpoint }
        }
        found = now
        dialFound()
    }

    /// Only the smaller node id connects to a discovered phone (spec), once at a time.
    private func dialFound() {
        guard running else { return }
        for (node, endpoint) in found where nodeId < node && byNode[node] == nil && !dialing.contains(node) {
            dialing.insert(node)
            let c = NWConnection(to: endpoint, using: .tcp)
            run(c, dialed: true) { [weak self] in self?.dialing.remove(node) }
        }
    }

    private func retryLoop() {
        q.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.running else { return }
            self.dialFound(); self.retryLoop()
        }
    }

    /// While the phone at that address is linked another way (it dialed this phone), it isn't dialed again.
    private func dialManual(_ g: Int, _ host: String, _ port: UInt16) {
        guard g == manualGen, let p = NWEndpoint.Port(rawValue: port) else { return }
        if let n = manualNode, byNode[n] != nil {
            q.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in self?.dialManual(g, host, port) }
            return
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        manualConn = c
        run(c, dialed: true, failed: { [weak self] in self?.note = "can't reach \(host):\(port), retrying" },
            hello: { [weak self] node in if g == self?.manualGen { self?.manualNode = node } }) { [weak self] in
            guard let self, g == self.manualGen else { return }
            self.q.asyncAfter(deadline: .now() + Self.retryDelay) { self.dialManual(g, host, port) }
        }
        report()
    }

    // MARK: - One link

    /// Runs one connection: HELLO both ways, then packets. `dialed`: this phone opened it. `hello` gets the other
    /// side's node id; `ended` runs once when the connection closes or fails.
    private func run(_ c: NWConnection, dialed: Bool, failed: (() -> Void)? = nil, hello: ((String) -> Void)? = nil,
                     ended: (() -> Void)? = nil) {
        var id: String?, linkNode: String?
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            if let id {
                links.removeValue(forKey: id)
                if let n = linkNode, byNode[n] == id { byNode.removeValue(forKey: n) } // unless a newer link replaced it
                router.peerDown(id)
            }
            report()
            ended?()
        }
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.note = ""
                c.send(content: Self.frame(Self.hello + Data(self.nodeId.utf8)), completion: .contentProcessed { _ in })
                self.q.asyncAfter(deadline: .now() + Self.helloWait) { if id == nil && !finished { c.cancel() } } // no HELLO in time
                self.readHello(c) { node in
                    guard let node, node != self.nodeId, !finished else { c.cancel(); return }
                    hello?(node)
                    guard self.links.count < Self.maxLinks else { c.cancel(); return }
                    let now = Date()
                    if let old = self.byNode[node], let o = self.links[old] {
                        // spec "Restarts and duplicate links": both phones keep the same link
                        let ageMs = Int64(now.timeIntervalSince(o.since) * 1000)
                        guard DuplicateLinks.keepNew(myId: self.nodeId, remoteId: node, newDialedByMe: dialed,
                                                     oldDialedByMe: o.dialed, oldAgeMs: ageMs) else { c.cancel(); return }
                        o.conn.cancel()
                    }
                    self.count += 1
                    let peer = Self.prefix + node + "#" + String(self.count)
                    id = peer; linkNode = node
                    self.links[peer] = (node, c, dialed, now)
                    self.byNode[node] = peer
                    self.router.peerUp(peer)
                    self.report()
                    self.readFrames(c, peer)
                }
            case .waiting: failed?(); c.cancel() // e.g. refused: retry on our own schedule
            case .failed, .cancelled: finish()
            default: break
            }
        }
        c.start(queue: q)
    }

    private func readHello(_ c: NWConnection, _ done: @escaping (String?) -> Void) {
        readFrame(c, max: Self.hello.count + 64) { body in
            guard let body, body.count > Self.hello.count, body.prefix(Self.hello.count) == Self.hello,
                  let node = String(data: body.dropFirst(Self.hello.count), encoding: .utf8) else { return done(nil) }
            done(node)
        }
    }

    private func readFrames(_ c: NWConnection, _ peer: String) {
        readFrame(c, max: Self.maxFrame) { [weak self] body in
            guard let self, let body else { c.cancel(); return }
            if let p = Packet.decode(body) { self.router.receive(from: peer, p) }
            self.readFrames(c, peer)
        }
    }

    /// One frame: a 4-byte big-endian length (1...max), then that many bytes. nil if the link broke or the length is wrong.
    private func readFrame(_ c: NWConnection, max: Int, _ done: @escaping (Data?) -> Void) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { head, _, _, error in
            guard let head, head.count == 4, error == nil else { return done(nil) }
            let n = head.reduce(0) { $0 << 8 | Int($1) }
            guard n >= 1, n <= max else { return done(nil) }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, error in
                guard let body, body.count == n, error == nil else { return done(nil) }
                done(body)
            }
        }
    }

    private static func frame(_ b: Data) -> Data {
        Data([UInt8(b.count >> 24 & 0xFF), UInt8(b.count >> 16 & 0xFF), UInt8(b.count >> 8 & 0xFF), UInt8(b.count & 0xFF)]) + b
    }

    /// Whether iOS refused Local Network to DarkProof (the Bonjour browser waits with "policy denied"). Any thread.
    var localNetworkDenied: Bool { deniedLock.lock(); defer { deniedLock.unlock() }; return _denied }
    private let deniedLock = NSLock()
    private var _denied = false
    private func setDenied(_ v: Bool) {
        deniedLock.lock(); let changed = _denied != v; _denied = v; deniedLock.unlock()
        if changed { note = v ? "Local Network not allowed" : ""; report() }
    }

    private func report() {
        guard running || manualTarget != nil else { onStatus(nil); return }
        var parts = ["\(links.count) link(s)"]
        if let m = manualTarget { parts.append("address \(m.host):\(m.port)") }
        if !note.isEmpty { parts.append(note) }
        onStatus("Wi-Fi network: " + parts.joined(separator: " · "))
    }
}
