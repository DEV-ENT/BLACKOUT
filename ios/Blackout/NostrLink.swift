import Foundation
import BlackoutCore

/// Links to public Nostr relays while there is internet (spec/FORMAT.md, "Internet relays"), like Android's NostrLink.
/// One peer for forwarding: the router gives it every packet and it hands the router what arrives for this phone's
/// mailboxes. Packets written on this phone go up first. Anyone else's (this phone bridging its neighbourhood) go up
/// only if no relay has them yet, and slowly, so the same packet isn't posted by every phone that holds it and relays
/// don't throttle us (RelayOutbox). Each relay link catches up one mailbox at a time (CatchUp), then gets new events
/// from one live subscription. All state is touched only on `q`.
final class NostrLink: NSObject, URLSessionWebSocketDelegate {
    static let peer = "nostr"
    /// Free public relays that stored a 22 KB event of this kind from a new key (tested 2026-11-06).
    static let relays = ["wss://nos.lol", "wss://relay.damus.io", "wss://relay.primal.net", "wss://nostr.mom", "wss://nostr.oxtr.dev", "wss://relay.ditto.pub"]
    /// Through Tor: nos.lol and nostr.mom don't answer Tor exits (tested 2026-11-06), so two others take their place.
    static let torRelays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nostr.oxtr.dev", "wss://relay.ditto.pub", "wss://relay.nostr.net", "wss://nostr.data.haus"]
    private static let tick = 1.5           // at most one own packet per tick
    private static let bridgeEvery = 3      // and one bridged packet every 3 ticks
    private static let checkEvery = 10.0    // how often to ask relays which bridged packets they have
    private static let checkWait = 6.0      // how long to wait for their answers
    private static let checkBatch = 50
    private static let rest = 600.0         // pause posting to a relay that says to slow down
    private static let catchUpWait: Int64 = 20 // seconds: a catch-up REQ with no EOSE by then is given up on this link

    private let q = DispatchQueue(label: "nostr")
    private let router: MeshRouter
    private let key = NostrKey() // a new throwaway key every start: relays can't link sessions
    private let mailboxes: () -> [UInt16]
    private let onStatus: (String?) -> Void
    private var session: URLSession!       // direct
    private var torSession: URLSession?    // through the app's own Tor (InAppTor), once it has a circuit
    private var tasks: [String: URLSessionWebSocketTask] = [:]   // url -> socket
    private var open = Set<String>()
    private var backoff: [String: Double] = [:]
    private var resting: [String: Date] = [:]                     // relay -> post again after
    private let outbox = RelayOutbox(sent: UserDefaults.standard.stringArray(forKey: "relaySent") ?? [])
    private let since = RelaySince(UserDefaults.standard.string(forKey: "relaySince") ?? "")
    private var catchUps: [String: CatchUp] = [:]                  // relay -> its catch-up
    private var events: [String: (id: String, author: String)] = [:] // packet id -> event, for reports
    private var running = false
    private var up = false
    private var checking = false
    private var ticks = 0
    private var live = "live" + String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
    private var timers: [DispatchSourceTimer] = []
    private var viaTor: Bool
    private var torOK: Bool?            // with Tor: whether the check said traffic leaves through Tor; nil without
    private var torChecking = false
    private var saver = false           // "Battery saver": lookups 4× less often, bridged packets more slowly

    private let onRelays: (String) -> Void // a packet went up to the relays, or they had it already

    init(router: MeshRouter, viaTor: Bool, mailboxes: @escaping () -> [UInt16], onRelays: @escaping (String) -> Void,
         onStatus: @escaping (String?) -> Void) {
        self.router = router; self.viaTor = viaTor; self.mailboxes = mailboxes; self.onRelays = onRelays; self.onStatus = onStatus
        torOK = viaTor ? false : nil
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    var isUp: Bool { q.sync { up } }
    var connected: Int { q.sync { open.count } }
    var total: Int { Self.relays.count } // the Tor list is as long
    private var relays: [String] { viaTor ? Self.torRelays : Self.relays }
    /// With "Connect through Tor": true while traffic is known to leave through Tor, false while waiting. Nil without.
    var throughTor: Bool? { q.sync { torOK } }

    func start() { q.async { self.startNow() } }
    func stop() { q.async { self.stopNow() } }

    /// "Battery saver" on or off: the phone's own messages still go up at once; lookups for bridged packets come every
    /// 40 s instead of 10, bridged packets go up every 8 ticks instead of 3, and lost relays are retried less often.
    func setSaver(_ on: Bool) {
        q.async {
            guard self.saver != on else { return }
            self.saver = on
            guard self.running else { return }
            self.timers.forEach { $0.cancel() }
            self.timers = self.makeTimers()
        }
    }

    private func makeTimers() -> [DispatchSourceTimer] {
        [every(Self.tick) { $0.pump() }, every(saver ? Self.checkEvery * 4 : Self.checkEvery) { $0.check() }]
    }

    /// Turns "Connect through Tor" on or off: drops every relay link and links again.
    func setTor(_ on: Bool) {
        q.async {
            let was = self.running
            self.stopNow()
            self.viaTor = on; self.torOK = on ? false : nil
            if was { self.startNow() } else { self.report() }
        }
    }

    private func startNow() {
        guard !running else { return }
        running = true
        relays.forEach(connect)
        timers = makeTimers()
        report()
    }

    private func stopNow() {
        running = false
        timers.forEach { $0.cancel() }; timers = []
        tasks.values.forEach { $0.cancel(with: .goingAway, reason: nil) }
        tasks = [:]; open = []; catchUps = [:]
        if up { up = false; router.peerDown(Self.peer) }
        save()
        report()
    }

    private func every(_ s: Double, _ f: @escaping (NostrLink) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + s, repeating: s)
        t.setEventHandler { [weak self] in if let self { f(self) } }
        t.resume()
        return t
    }

    /// The groups changed: every relay gets the new live subscription and catches up the new mailboxes. Any thread.
    func resubscribe() {
        q.async {
            let old = self.live
            self.live = "live" + String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
            let boxes = self.mailboxes()
            for url in self.open {
                self.tasks[url]?.send(.string(Nostr.close(old))) { _ in }
                self.tasks[url]?.send(.string(Nostr.live(self.live, mailboxes: boxes))) { _ in }
                self.catchUps[url]?.add(boxes)
                if let r = self.catchUps[url]?.next(now: Self.nowS()) { self.tasks[url]?.send(.string(r.text)) { _ in } }
            }
        }
    }

    /// Called by the router: queues the packet unless it came from the relays, is on them already or is too old.
    /// `mine` = written on this phone (a message or a receipt). Older own packets may be on the relays already (the
    /// app can be killed before it saves what it posted), so they are looked up first, like anyone else's.
    func send(_ p: Packet, mine: Bool) { q.async { self.outbox.offer(p, mine: mine) } }

    // MARK: - Tor

    /// Waits for the app's own Tor, then asks the Tor Project through it whether traffic leaves through Tor; links to
    /// the relays if so, else tries again soon.
    private func checkTor() {
        guard running, !torChecking else { return }
        guard let conf = InAppTor.shared.sessionConfiguration() else { // Tor is still starting
            q.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkTor() }
            return
        }
        if torSession == nil {
            conf.waitsForConnectivity = false
            torSession = URLSession(configuration: conf, delegate: self, delegateQueue: nil)
        }
        guard let s = torSession else { return }
        torChecking = true
        var r = URLRequest(url: TorCheck.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.httpShouldHandleCookies = false
        s.dataTask(with: r) { [weak self] data, _, _ in
            guard let self else { return }
            self.q.async {
                self.torChecking = false
                guard self.running, self.viaTor else { return }
                let ok = data.map(TorCheck.isTor) ?? false
                self.torOK = ok
                if ok { self.relays.forEach(self.connect) }
                else { self.q.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkTor() } } // Tor may still be starting
                self.report()
            }
        }.resume()
    }

    // MARK: - Sockets

    private func connect(_ url: String) {
        guard running, let u = URL(string: url), tasks[url] == nil else { return }
        if viaTor && torOK != true { checkTor(); return } // with Tor: only after the check, and only through it
        guard let s = viaTor ? torSession : session else { return }
        let t = s.webSocketTask(with: u)
        t.maximumMessageSize = 1 << 20
        tasks[url] = t
        t.resume()
        receive(url, t)
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        q.async {
            guard let url = self.tasks.first(where: { $0.value === t })?.key else { return }
            self.open.insert(url); self.backoff[url] = nil
            let boxes = self.mailboxes()
            t.send(.string(Nostr.live(self.live, mailboxes: boxes))) { _ in }
            let cu = CatchUp(relay: url, since: self.since)
            cu.add(boxes)
            self.catchUps[url] = cu
            if let r = cu.next(now: Self.nowS()) { t.send(.string(r.text)) { _ in } }
            if !self.up { self.up = true; self.router.peerUp(Self.peer) } // the router then offers every stored packet
            self.report()
        }
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
        if let ok = Nostr.ok(text) {
            if !ok.accepted {
                #if DEBUG
                DebugLog.write("relay \(url) refused an event: \(ok.reason.prefix(150))")
                #endif
                if Nostr.isThrottle(ok.reason) { resting[url] = Date().addingTimeInterval(Self.rest) }
            }
            if let id = outbox.answer(relay: url, ok) { onRelays(id) } // "Sent" only once a relay took it
            return
        }
        if let e = Nostr.end(text) {
            if let r = catchUps[url]?.end(e.subId, complete: e.complete, now: Self.nowS()) { tasks[url]?.send(.string(r.text)) { _ in } } // older page or next mailbox
            return
        }
        guard let r = Nostr.received(text) else { return }
        events[r.packet.id] = (r.eventId, r.pubkey)
        if events.count > 2_000 { events.removeAll() }
        if r.subId == live { catchUps[url]?.live(Packet.mailbox(of: r.packet.id), createdAt: r.createdAt, now: Self.nowS()) }
        else { catchUps[url]?.event(r.subId, createdAt: r.createdAt) }
        if let id = outbox.fromRelay(r.packet) { onRelays(id) }
        router.receive(from: Self.peer, r.packet) // also answers to the #x lookups: the router ignores packets it already has
    }

    private func lost(_ url: String, _ t: URLSessionWebSocketTask) {
        guard tasks[url] === t else { return }
        tasks[url] = nil; open.remove(url); catchUps[url] = nil
        if open.isEmpty && up { up = false; router.peerDown(Self.peer) }
        if open.isEmpty && torOK == true { torOK = false } // Tor may have lost its circuits: check again before linking
        report()
        guard running else { return }
        let wait = min((backoff[url] ?? 2.5) * 2, saver ? 480 : 120) // no internet: try again, less and less often
        backoff[url] = wait
        q.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect(url) }
    }

    // MARK: - Posting

    /// Every tick: one own packet, else (every few ticks) one bridged packet no relay had, else pending reports. Only
    /// to relays that aren't resting; with none, packets stay queued.
    private func pump() {
        guard running else { return }
        ticks += 1
        outbox.expire() // posts no relay accepted in time go back in the queue
        let now = Date()
        let ready = open.filter { (resting[$0] ?? .distantPast) < now }
        if !ready.isEmpty {
            if let n = outbox.next(bridged: ticks % (saver ? 8 : Self.bridgeEvery) == 0) { post(n.packet, fromOwn: n.fromOwn, to: ready) }
            else { sendReports() }
        }
        save()
    }

    private func post(_ p: Packet, fromOwn: Bool, to relays: Set<String>) {
        let e = Nostr.event(p, pubkey: key.pubkey, sign: key.sign)
        let msg = Nostr.publish(e)
        for url in relays { tasks[url]?.send(.string(msg)) { _ in } }
        outbox.posted(eventId: e["id"] as? String ?? "", p, fromOwn: fromOwn, relays: relays)
    }

    /// The sent list and the catch-up starts, when they changed.
    private func save() {
        if outbox.changed { UserDefaults.standard.set(outbox.sentList(), forKey: "relaySent") }
        if since.changed { UserDefaults.standard.set(since.save(), forKey: "relaySince") }
    }

    /// Asks the relays which of the newest unchecked bridged packets they have; the rest get posted. Also ends stuck
    /// catch-ups.
    private func check() {
        guard running else { return }
        catchUpTimeouts()
        guard !checking, !open.isEmpty else { return }
        let batch = outbox.toCheck(Self.checkBatch)
        guard !batch.isEmpty else { return }
        checking = true
        let subId = "have" + String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let req = Nostr.have(subId, packetIds: batch.map(\.id))
        for url in open { tasks[url]?.send(.string(req)) { _ in } }
        q.asyncAfter(deadline: .now() + Self.checkWait) { [weak self] in
            guard let self else { return }
            for url in self.open { self.tasks[url]?.send(.string(Nostr.close(subId))) { _ in } }
            for id in self.outbox.checked(batch) { self.onRelays(id) } // only copies with the same contents count (Nostr.digest)
            self.checking = false
        }
    }

    private func catchUpTimeouts() {
        let now = Self.nowS()
        for (url, cu) in catchUps {
            guard let c = cu.current, now - cu.sentAt >= Self.catchUpWait else { continue }
            tasks[url]?.send(.string(Nostr.close(c.subId))) { _ in }
            if let r = cu.end(c.subId, complete: false, now: now) { tasks[url]?.send(.string(r.text)) { _ in } }
        }
    }

    private static func nowS() -> Int64 { Int64(Date().timeIntervalSince1970) }

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
        guard running else { return onStatus(nil) }
        onStatus(torOK == false ? "Internet: waiting for Tor"
                 : "Internet: \(open.count) of \(relays.count) relays" + (torOK == true ? " through Tor" : ""))
    }
}
