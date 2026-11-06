import Foundation
import BlackoutCore

/// Links to public Nostr relays while there is internet (spec/FORMAT.md, "Internet relays"), like Android's NostrLink.
/// One peer for forwarding: the router gives it every packet and it hands the router what arrives for this phone's
/// mailboxes. Packets written on this phone go up first. Anyone else's (this phone bridging its neighbourhood) go up
/// only if no relay has them yet, and slowly, so the same packet isn't posted by every phone that holds it and relays
/// don't throttle us. All state is touched only on `q`.
final class NostrLink: NSObject, URLSessionWebSocketDelegate {
    static let peer = "nostr"
    /// Free public relays that stored a 22 KB event of this kind from a new key (tested 2026-11-06).
    static let relays = ["wss://nos.lol", "wss://relay.damus.io", "wss://relay.primal.net", "wss://nostr.mom", "wss://nostr.oxtr.dev", "wss://relay.ditto.pub"]
    private static let tick = 1.5           // at most one own packet per tick
    private static let bridgeEvery = 3      // and one bridged packet every 3 ticks
    private static let checkEvery = 10.0    // how often to ask relays which bridged packets they have
    private static let checkWait = 6.0      // how long to wait for their answers
    private static let checkBatch = 50
    private static let rest = 600.0         // pause posting to a relay that says to slow down
    private static let freshMs: Int64 = 120_000 // own packets younger than this go up without asking first

    private let q = DispatchQueue(label: "nostr")
    private let router: MeshRouter
    private let key = NostrKey() // a new throwaway key every start: relays can't link sessions
    private let mailboxes: () -> [UInt16]
    private let onStatus: (String?) -> Void
    private var session: URLSession!
    private var tasks: [String: URLSessionWebSocketTask] = [:]   // url -> socket
    private var open = Set<String>()
    private var backoff: [String: Double] = [:]
    private var resting: [String: Date] = [:]                     // relay -> post again after
    private var own: [String: Packet] = [:]          // written on this phone: up first, newest first
    private var candidates: [String: Packet] = [:]   // anyone else's, not yet checked with the relays
    private var missing: [String: Packet] = [:]      // checked: no relay has them, so this phone posts them
    private var fromRelays = Set<String>()
    private var sentList = UserDefaults.standard.stringArray(forKey: "relaySent") ?? [] // on relays already, oldest first
    private lazy var sent = Set(sentList)
    private var events: [String: (id: String, author: String)] = [:] // packet id -> event, for reports
    private var running = false
    private var up = false
    private var checking = false
    private var ticks = 0
    private var sub = "dp" + String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
    private var timers: [DispatchSourceTimer] = []

    init(router: MeshRouter, mailboxes: @escaping () -> [UInt16], onStatus: @escaping (String?) -> Void) {
        self.router = router; self.mailboxes = mailboxes; self.onStatus = onStatus
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    var isUp: Bool { q.sync { up } }
    var connected: Int { q.sync { open.count } }
    var total: Int { Self.relays.count }

    func start() {
        q.async {
            guard !self.running else { return }
            self.running = true
            Self.relays.forEach(self.connect)
            self.timers = [self.every(Self.tick) { $0.pump() }, self.every(Self.checkEvery) { $0.check() }]
            self.report()
        }
    }

    func stop() {
        q.async {
            self.running = false
            self.timers.forEach { $0.cancel() }; self.timers = []
            self.tasks.values.forEach { $0.cancel(with: .goingAway, reason: nil) }
            self.tasks = [:]; self.open = []
            if self.up { self.up = false; self.router.peerDown(Self.peer) }
            self.report()
        }
    }

    private func every(_ s: Double, _ f: @escaping (NostrLink) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + s, repeating: s)
        t.setEventHandler { [weak self] in if let self { f(self) } }
        t.resume()
        return t
    }

    /// The group changed: ask every relay for the new mailboxes.
    func resubscribe() {
        q.async {
            let old = self.sub
            self.sub = "dp" + String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
            for url in self.open { self.tasks[url]?.send(.string(Nostr.close(old))) { _ in }; self.subscribe(url) }
        }
    }

    /// Called by the router: queues the packet unless it came from the relays, is on them already or is too old.
    /// `mine` = written on this phone. Older own packets may be on the relays already (the app can be killed before it
    /// saves what it posted), so they are looked up first, like anyone else's.
    func send(_ p: Packet, mine: Bool) {
        q.async {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            guard !self.fromRelays.contains(p.id), !self.sent.contains(p.id), p.ts >= now - Nostr.keepSeconds * 1000 else { return }
            if mine && p.ts > now - Self.freshMs { self.own[p.id] = p }
            else if self.missing[p.id] == nil, self.candidates.count < 5_000 { self.candidates[p.id] = p }
        }
    }

    // MARK: - Sockets

    private func connect(_ url: String) {
        guard running, let u = URL(string: url) else { return }
        let t = session.webSocketTask(with: u)
        t.maximumMessageSize = 1 << 20
        tasks[url] = t
        t.resume()
        receive(url, t)
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        q.async {
            guard let url = self.tasks.first(where: { $0.value === t })?.key else { return }
            self.open.insert(url); self.backoff[url] = nil
            self.subscribe(url)
            if !self.up { self.up = true; self.router.peerUp(Self.peer) } // the router then offers every stored packet
            self.report()
        }
    }

    private func subscribe(_ url: String) {
        tasks[url]?.send(.string(Nostr.subscribe(sub, mailboxes: mailboxes()))) { _ in }
    }

    private func receive(_ url: String, _ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard self.tasks[url] === t else { return }
                switch result {
                case .failure: self.lost(url, t)
                case .success(let m):
                    if case .string(let text) = m { self.handle(url, text) }
                    self.receive(url, t)
                }
            }
        }
    }

    private func handle(_ url: String, _ text: String) {
        if let why = Nostr.refusal(text) {
            #if DEBUG
            DebugLog.write("relay \(url) refused an event: \(why.prefix(150))")
            #endif
            if Nostr.isThrottle(why) { resting[url] = Date().addingTimeInterval(Self.rest) }
            return
        }
        guard let r = Nostr.received(text) else { return }
        fromRelays.insert(r.packet.id)
        if fromRelays.count > 5_000 { fromRelays.removeFirst() }
        events[r.packet.id] = (r.eventId, r.pubkey)
        if events.count > 2_000 { events.removeAll() }
        router.receive(from: Self.peer, r.packet) // also answers to have(): the router ignores packets it already has
    }

    private func lost(_ url: String, _ t: URLSessionWebSocketTask) {
        guard tasks[url] === t else { return }
        tasks[url] = nil; open.remove(url)
        if open.isEmpty && up { up = false; router.peerDown(Self.peer) }
        report()
        guard running else { return }
        let wait = min((backoff[url] ?? 2.5) * 2, 120) // no internet: try again, less and less often
        backoff[url] = wait
        q.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect(url) }
    }

    // MARK: - Posting

    /// Every tick: one own packet, else (every few ticks) one bridged packet no relay had, else pending reports.
    private func pump() {
        guard running, !open.isEmpty else { return }
        ticks += 1
        if let p = own.values.max(by: { $0.ts < $1.ts }) {
            own[p.id] = nil; post(p)
        } else if ticks % Self.bridgeEvery == 0, let p = missing.values.max(by: { $0.ts < $1.ts }) {
            missing[p.id] = nil
            if !fromRelays.contains(p.id) { post(p) }
        } else {
            sendReports()
        }
    }

    private func post(_ p: Packet) {
        let msg = Nostr.publish(Nostr.event(p, pubkey: key.pubkey, sign: key.sign))
        let now = Date()
        for url in open where (resting[url] ?? .distantPast) < now { tasks[url]?.send(.string(msg)) { _ in } }
        markSent(p.id)
    }

    private func markSent(_ id: String) {
        sentList.append(id); sent.insert(id)
        if sentList.count > 3_000 { sent.remove(sentList.removeFirst()) }
        UserDefaults.standard.set(sentList, forKey: "relaySent")
    }

    /// Asks the relays which of the newest unchecked bridged packets they have; the rest go to `missing`.
    private func check() {
        guard running, !checking, !open.isEmpty, !candidates.isEmpty else { return }
        let batch = candidates.values.sorted { $0.ts > $1.ts }.prefix(Self.checkBatch)
        batch.forEach { candidates[$0.id] = nil }
        checking = true
        let subId = "have" + String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let req = Nostr.have(subId, packetIds: batch.map(\.id))
        for url in open { tasks[url]?.send(.string(req)) { _ in } }
        q.asyncAfter(deadline: .now() + Self.checkWait) { [weak self] in
            guard let self else { return }
            for url in self.open { self.tasks[url]?.send(.string(Nostr.close(subId))) { _ in } }
            for p in batch { if self.fromRelays.contains(p.id) { self.markSent(p.id) } else { self.missing[p.id] = p } }
            self.checking = false
        }
    }

    private func sendReports() {
        var done: [String] = []
        for id in Moderation.pendingReports {
            guard let e = events[id] else { continue } // only messages that came from relays can be reported there
            let msg = Nostr.publish(Nostr.report(eventId: e.id, author: e.author, pubkey: key.pubkey, sign: key.sign))
            for url in open { tasks[url]?.send(.string(msg)) { _ in } }
            done.append(id)
        }
        if !done.isEmpty { DispatchQueue.main.async { Moderation.reportsSent(done) } }
    }

    private func report() {
        onStatus(running ? "Internet: \(open.count) of \(Self.relays.count) relays" : nil)
    }
}
