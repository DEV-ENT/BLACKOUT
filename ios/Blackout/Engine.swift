import Foundation
import CoreBluetooth
import UIKit
import BlackoutCore

/// Owns the one Engine. It starts as soon as the app process starts, if a group is set up, so it also runs when iOS
/// relaunches DarkProof in the background for Bluetooth (BleLink's restore identifiers), with no screen at all.
final class Mesh: ObservableObject {
    static let shared = Mesh()
    @Published private(set) var engine: Engine?

    /// Starts the mesh for the saved group, if there is one. Safe to call more than once.
    func startIfSetUp() {
        let d = UserDefaults.standard
        guard engine == nil, let code = d.string(forKey: "code"), !code.isEmpty else { return }
        engine = Engine(name: d.string(forKey: "name") ?? "", code: code)
    }

    /// Starts the mesh right after setup. Bluetooth starts first; the Wi-Fi links (which ask for Local Network)
    /// only once the Bluetooth question is answered, so iOS asks one thing at a time.
    func start(name: String, code: String) {
        if engine == nil { engine = Engine(name: name, code: code, askInOrder: true) }
    }
}

/// State shared between the transports and the UI, like the Android MeshEngine.
final class Engine: ObservableObject {
    static let maxTtl = MeshRouter.maxTtl
    private static let handedOffMax = 2_000  // "Sent" labels remembered across restarts
    private static let maxPublic = 2_000     // Public messages kept on the phone; older ones are removed
    private static let week: Int64 = 7 * 24 * 3_600_000
    /// This group's messages and the Public channel's, oldest first, without blocked people and reported messages.
    @Published private(set) var messages: [Message] = []
    /// Every saved group's messages and the Public channel's, likewise; `Message.group` tells which group.
    @Published private(set) var allMessages: [Message] = []
    @Published private(set) var status: [String: String] = [:] // transport -> status line
    @Published private(set) var phones = 0        // other devices linked directly, each counted once
    @Published private(set) var bluetoothLinks = 0
    @Published private(set) var wifiLinks = 0
    @Published private(set) var wifiNetworkLinks = 0 // phones linked over a Wi-Fi network (WifiLink)
    @Published private(set) var radioLinked = false
    @Published private(set) var meshcoreLinked = false
    @Published private(set) var relaysLinked = 0     // internet relays connected right now (NostrLink)
    @Published private(set) var throughTor: Bool?    // "Connect through Tor": true when checked, false while waiting
    @Published private(set) var linkedNodes: Set<String> = [] // node ids linked directly right now
    @Published private(set) var name: String
    @Published private(set) var deliveries = Deliveries()  // who confirmed which message (spec/FORMAT.md, "Delivery receipts")
    @Published private(set) var handedOff: Set<String> = [] // ids of my messages given to a phone, radio or the relays
    /// A check-in waiting for its GPS fix (up to 10 s): the buttons show "Sending…" and stay disabled meanwhile.
    @Published private(set) var checkInSending: CheckIn?
    @Published private(set) var bluetooth = CBManagerState.unknown  // this phone's Bluetooth: off, not allowed…
    @Published private(set) var localNetworkDenied = false          // Local Network refused: no Wi-Fi links
    @Published private(set) var networkStarted = false              // the Wi-Fi links started (after the Bluetooth question)
    @Published private(set) var torSlow = false                     // "Connect through Tor" found no way out for 2 minutes
    private var torWaitingSince: Date?
    let deviceId: String
    let startedAt = Int64(Date().timeIntervalSince1970 * 1000)

    /// A saved group's keys (spec/FORMAT.md, "Encryption" and "Delivery receipts").
    struct Keys { let code: String; let group: GroupCrypto; let receipts: GroupCrypto }
    private let keyLock = NSLock()
    private var keyCache: [String: Keys] = [:] // code -> keys: each derivation takes 120,000 rounds, so only once
    private let cryptoLock = NSLock()          // guards the three below: read from the router's thread
    private var _active: Keys?                 // the group on screen
    private var _others: [Keys] = []           // the other saved groups: read, alerted and confirmed too
    private var _public: GroupCrypto?
    private var keySet: (active: Keys?, others: [Keys], pub: GroupCrypto?) { cryptoLock.withLock { (_active, _others, _public) } }
    private var activeCode: String             // main thread: the group on screen, even while its keys are derived

    private let idsLock = NSLock()
    private var mine = Set<String>()       // ids of messages written on this phone; guarded by idsLock
    private var myReceipts = Set<String>() // ids of receipts written on this phone (they go up to the relays first); idsLock
    private var sentIds: RecentIds         // my messages already handed off, saved on the phone; idsLock
    private var receiptIds = Set<String>() // receipt packets this phone can open, kept off LoRa; guarded by idsLock

    private let storeLock = NSLock()
    private var index: [String: StoreCap.Entry] = [:] // every stored packet, for the store cap; guarded by storeLock
    private var indexBytes = 0                        // storeLock
    private var allKeys = false                       // every saved group's key was tried on the whole store; storeLock
    private var compacting = false                    // storeLock
    private let work = DispatchQueue(label: "engine", qos: .userInitiated) // loading, keys and compaction, in order

    private var raw: [Message] = []          // main thread: every readable message, before moderation
    private var rawIds = Set<String>()       // main thread
    private var receiptMsgs: [String: Message] = [:] // main thread: opened receipts by packet id
    private var pendingAcks: [(id: String, key: GroupCrypto)] = [] // main thread: messages to confirm, with their group's receipt key
    private var firstAck: Int64 = 0, lastAck: Int64 = 0            // main thread

    private let store = PacketStore()
    private(set) var router: MeshRouter!
    private var ble: BleLink!
    private var mc: MultipeerLink!
    private(set) var lora: LoraLink!
    private(set) var meshcore: MeshCoreLink!
    private(set) var wifi: WifiLink!
    private(set) var nostr: NostrLink!

    /// Starts the transports at once; keys and stored messages are read in the background (no 120,000-round key
    /// derivation or store reading on the main thread), then published.
    init(name: String, code: String, askInOrder: Bool = false) {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "device") { deviceId = id } else {
            deviceId = String(UUID().uuidString.lowercased().prefix(12)) // same shape as Android ids, e.g. 7c0d995b-2c4
            d.set(deviceId, forKey: "device")
        }
        self.name = name
        activeCode = code
        sentIds = RecentIds(max: Self.handedOffMax, d.stringArray(forKey: "handedOff") ?? [])
        handedOff = Set(sentIds.list)
        router = MeshRouter(send: { [weak self] peer, p in self?.route(peer, p) },
                            deliver: { [weak self] p in self?.onDeliver(p) })
        mc = MultipeerLink(nodeId: deviceId, router: router) { [weak self] s in self?.setStatus("1-mc", s) }
        ble = BleLink(nodeId: deviceId, router: router) { [weak self] s in self?.setStatus("2-ble", s) }
        lora = LoraLink(router: router) { [weak self] s in self?.setStatus("3-lora", s) }
        meshcore = MeshCoreLink(router: router) { [weak self] s in self?.setStatus("3b-meshcore", s) }
        wifi = WifiLink(nodeId: deviceId, router: router) { [weak self] s in self?.setStatus("4-wifi", s) }
        nostr = NostrLink(router: router, viaTor: d.bool(forKey: "tor"), mailboxes: { [weak self] in self?.mailboxes() ?? [] },
                          onRelays: { [weak self] id in self?.markHandedOff(id) }) { [weak self] s in
            self?.setStatus("5-internet", s)
        }
        nostr.setSaver(Self.saver)
        if d.object(forKey: "internet") as? Bool ?? true { nostr.start() }
        #if DEBUG
        DebugLog.start()
        BleLink.restoredHook = { DebugLog.write("bluetooth " + $0) }
        #endif
        ble.start()
        lora.start()
        meshcore.start()
        if askInOrder && CBManager.authorization == .notDetermined {
            afterBluetoothAnswer(tries: 240) { [weak self] in self?.startNetwork() }
        } else {
            startNetwork()
        }
        work.async { self.startUp(code) }
    }

    /// Apple peer-to-peer and Wi-Fi networks: both make iOS ask for Local Network.
    private func startNetwork() {
        mc.start()
        if wifiWanted { wifi.start() }
        networkStarted = true
    }

    /// Waits (at most `tries` × 0.5 s) until the user has answered the Bluetooth question. Main thread.
    private func afterBluetoothAnswer(tries: Int, _ then: @escaping () -> Void) {
        if CBManager.authorization != .notDetermined || tries <= 0 { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.afterBluetoothAnswer(tries: tries - 1, then) }
    }

    /// "Battery saver" (Connections): no Wi-Fi network links and fewer relay requests. Bluetooth keeps running.
    static var saver: Bool { UserDefaults.standard.bool(forKey: "saver") }
    private var wifiWanted: Bool { (UserDefaults.standard.object(forKey: "wifiNetwork") as? Bool ?? true) && !Self.saver }

    func setSaver(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "saver")
        if wifiWanted { wifi.start() } else { wifi.stop() }
        nostr.setSaver(on)
    }

    var statusLines: [String] { status.keys.sorted().compactMap { status[$0] } }

    /// Turns linking over Wi-Fi networks on or off (Connections screen), and remembers it.
    func setWifi(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "wifiNetwork")
        if wifiWanted { wifi.start() } else { wifi.stop() }
    }

    /// Turns the internet relays on or off (Connections screen), and remembers it.
    func setInternet(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "internet")
        if on { nostr.start() } else { nostr.stop() }
    }

    /// Turns "Connect through Tor" on or off (Connections screen), and remembers it.
    func setTor(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "tor")
        nostr.setTor(on)
    }

    /// This phone's relay mailboxes (spec/FORMAT.md, "Mailboxes"): its group's, the other saved groups', the Public
    /// channel's last. Any thread.
    private func mailboxes() -> [UInt16] {
        let k = keySet
        var out: [UInt16] = []
        for m in [k.active?.group.mailbox].compactMap({ $0 }) + k.others.map(\.group.mailbox) + [Nostr.publicMailbox] where !out.contains(m) {
            out.append(m)
        }
        return out
    }

    /// The cached keys of `code`, derived the first time (slow: 120,000 rounds). Any thread; never holds a lock while
    /// deriving, so the main thread never waits for another group's key.
    private func keys(_ code: String) -> Keys {
        if let k = keyLock.withLock({ keyCache[code] }) { return k }
        let g = GroupCrypto(code: code), k = Keys(code: code, group: g, receipts: g.receipts())
        return keyLock.withLock { if let other = keyCache[code] { return other }; keyCache[code] = k; return k }
    }

    /// Switches to another group (or just another name) without restarting the radios: every phone relays every
    /// group anyway, and saved groups' messages are already read. Only the name changed: nothing else happens. A new
    /// group's key is derived in the background. Call on the main thread.
    func rejoin(name: String, code: String) {
        self.name = name
        guard code != activeCode else { return }
        flushAcks() // confirmations owed so far go out first
        activeCode = code
        refresh() // a saved group's messages show at once
        work.async { self.savedGroupsChanged(code) }
    }

    /// After blocking, unblocking or reporting: shows the messages again with the new rules. Main thread; no reading.
    func moderationChanged() { refresh() }

    // MARK: - Loading (background, on `work`)

    /// Passes stored packets on right away (no keys needed), then reads them with this group's and the Public key, then
    /// with the other saved groups' keys, then trims the store.
    private func startUp(_ code: String) {
        let now = Self.nowMs(), cut = now - Self.week
        var recent: [Packet] = [], seen = Set<String>()
        store.forEach { p in
            guard p.ts >= cut, !MeshRouter.inFuture(p.ts, now: now) else { return }
            seen.insert(p.id); recent.append(p)
            if recent.count >= 2_000 { recent.sort { $0.ts > $1.ts }; recent.removeLast(recent.count - 500) }
        }
        router.restore(recent, seenIds: seen) // the router keeps the newest 500
        let a = keys(code), pub = keys(GroupCrypto.publicCode).group
        cryptoLock.withLock { _active = a; _public = pub }
        load()
        nostr.resubscribe()
        savedGroupsChanged(code)
    }

    /// `code` is the group on screen and the saved list may have changed: derives the keys not seen before, reads the
    /// store again only if there are any, then trims the store.
    private func savedGroupsChanged(_ code: String) {
        let known = keyLock.withLock { Set(keyCache.keys) }
        var codes: [String] = []
        for c in SavedGroups.all().map(\.code) where c != code && !codes.contains(c) { codes.append(c) }
        let a = keys(code), o = codes.map(keys)
        cryptoLock.withLock { _active = a; _others = o }
        if !(codes + [code]).allSatisfy(known.contains) { load() }
        storeLock.withLock { allKeys = true }
        compact()
        nostr.resubscribe() // the relays now send every saved group's mailbox
    }

    /// Reads every stored packet with every key known so far: messages, receipts, my own ids and the store index.
    /// Packets dated more than 10 minutes ahead are removed. Publishes on the main thread.
    private func load() {
        let k = keySet, now = Self.nowMs()
        var msgs: [Message] = [], recs: [Message] = [], own = Set<String>(), ownR = Set<String>(), rIds = Set<String>()
        var idx: [String: StoreCap.Entry] = [:], future = Set<String>()
        store.forEach { stored in
            let p = MeshRouter.clamp(stored)
            guard idx[p.id] == nil else { return } // a record written twice
            if MeshRouter.inFuture(p.ts, now: now) { future.insert(p.id); return }
            let kind: StoreCap.Kind
            if let m = read(p, k) {
                msgs.append(m); if m.sender == deviceId { own.insert(m.id) }
                kind = m.isPublic ? .isPublic : .group
            } else if let r = readReceipt(p, k) {
                recs.append(r); rIds.insert(p.id); if r.sender == deviceId { ownR.insert(p.id) }
                kind = .group
            } else {
                kind = .unreadable
            }
            idx[p.id] = StoreCap.Entry(id: p.id, ts: p.ts, size: Packet.headerSize + p.cipher.count, kind: kind)
        }
        if !future.isEmpty {
            store.remove(future)
            #if DEBUG
            DebugLog.write("store: removed \(future.count) packets dated in the future")
            #endif
        }
        idsLock.withLock { mine.formUnion(own); myReceipts.formUnion(ownR); receiptIds.formUnion(rIds) }
        storeLock.withLock {
            for (id, e) in index where idx[id] == nil { idx[id] = e } // stored while reading
            index = idx; indexBytes = idx.values.reduce(0) { $0 + $1.size }
        }
        DispatchQueue.main.async {
            for m in msgs where self.rawIds.insert(m.id).inserted { self.raw.append(m) }
            self.raw.sort { $0.ts < $1.ts }
            for r in recs { self.receiptMsgs[r.id] = r }
            self.deliveries = Deliveries(Array(self.receiptMsgs.values))
            self.refresh()
        }
    }

    /// Keeps the store small, once every saved group's key has been tried: packets older than 7 days that no saved
    /// group can read go (phones stop passing them on after 7 days anyway), Public messages beyond the newest 2,000
    /// go, and then the store cap (StoreCap: about 40 MB and 20,000 packets, unreadable packets first). Same rules as
    /// the Android app (MeshEngine.compact).
    private func compact() {
        let drop: Set<String> = storeLock.withLock {
            compacting = false
            guard allKeys else { return [] }
            let cut = Self.nowMs() - Self.week
            var drop = Set(index.values.filter { $0.kind == .unreadable && $0.ts < cut }.map(\.id))
            let pub = index.values.filter { $0.kind == .isPublic }.sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
            if pub.count > Self.maxPublic { pub.prefix(pub.count - Self.maxPublic).forEach { drop.insert($0.id) } }
            drop.formUnion(StoreCap.overflow(index.values.filter { !drop.contains($0.id) }))
            for id in drop { if let e = index.removeValue(forKey: id) { indexBytes -= e.size } }
            return drop
        }
        guard !drop.isEmpty else { return }
        store.remove(drop)
        #if DEBUG
        DebugLog.write("store: removed \(drop.count) packets")
        #endif
        DispatchQueue.main.async {
            self.raw.removeAll { drop.contains($0.id) }; self.rawIds.subtract(drop)
            self.refresh()
        }
    }

    /// The store grew well past its cap while running: trim it in the background. Any thread.
    private func compactIfFull() {
        let full = storeLock.withLock {
            guard allKeys, !compacting, indexBytes > StoreCap.maxBytes / 10 * 11 || index.count > StoreCap.maxCount + 1_000 else { return false }
            compacting = true; return true
        }
        if full { work.async { self.compact() } }
    }

    private func indexed(_ p: Packet, _ kind: StoreCap.Kind) {
        storeLock.withLock {
            guard index[p.id] == nil else { return }
            index[p.id] = StoreCap.Entry(id: p.id, ts: p.ts, size: Packet.headerSize + p.cipher.count, kind: kind)
            indexBytes += Packet.headerSize + p.cipher.count
        }
    }

    // MARK: - Messages

    /// Shows the messages again: this group's and the Public channel's in `messages`, all groups' in `allMessages`,
    /// without blocked people and reported messages. Main thread.
    private func refresh() {
        let blocked = Moderation.blocked, hidden = Moderation.hidden // read once, not per message
        let visible = raw.filter { blocked[$0.sender] == nil && !hidden.contains($0.id) }
        allMessages = visible
        messages = visible.filter { $0.isPublic || $0.group == activeCode }
    }

    /// Adds a message in time order. Main thread.
    private func add(_ m: Message) {
        guard rawIds.insert(m.id).inserted else { return }
        let i = raw.lastIndex { $0.ts <= m.ts }.map { $0 + 1 } ?? 0
        raw.insert(m, at: i)
        refresh()
    }

    /// The saved name of the group whose code is `code` (`Message.group`), for alerts. Main thread.
    func groupName(_ code: String?) -> String {
        if code == activeCode { return UserDefaults.standard.string(forKey: "groupName") ?? "your group" }
        return SavedGroups.all().first { $0.code == code }?.name ?? "a saved group"
    }

    /// Writes a message from this phone, to the group on screen (or the saved group `group`, e.g. answering its
    /// "Are you safe?") or to the Public channel. Call on the main thread.
    /// Returns false if it is too long for a LoRa radio that is linked now (it still travels the other ways).
    @discardableResult func send(_ text: String, isPublic: Bool = false, photo: Data? = nil, group: String? = nil) -> Bool {
        let target = group.flatMap { $0.isEmpty ? nil : $0 } ?? activeCode
        let code = isPublic ? GroupCrypto.publicCode : target
        let cr = keys(code).group // cached; derived here only if the user writes within a second of switching
        let id = Packet.newId(mailbox: cr.mailbox), ts = Int64(Date().timeIntervalSince1970 * 1000)
        guard let c = try? cr.seal(id: id, ts: ts, sender: deviceId, name: name, text: text, photo: isPublic ? nil : photo)
        else { return true }
        let p = Packet(id: id, ts: ts, ttl: Self.maxTtl, cipher: c)
        idsLock.withLock { _ = mine.insert(id) }
        store.append(p)
        indexed(p, isPublic ? .isPublic : .group)
        add(Message(id: id, ts: ts, sender: deviceId, name: name, text: text, isPublic: isPublic, photo: isPublic ? nil : photo,
                    group: isPublic ? nil : target))
        router.publish(p)
        return (!lora.connected || Meshtastic.fits(p)) && (!meshcore.connected || MeshCore.fits(p))
    }

    /// Sends a check-in with this phone's battery level and, if you share it, your position (a fresh GPS fix can take
    /// up to 10 s: `checkInSending` is set meanwhile and a second tap is ignored). The haptic comes right away.
    /// `group`: a saved group other than the one on screen. Main thread.
    func checkIn(_ c: CheckIn, needs: Set<Need> = [], people: Int? = nil, group: String? = nil, done: (() -> Void)? = nil) {
        guard checkInSending == nil else { return }
        checkInSending = c
        UINotificationFeedbackGenerator().notificationOccurred(c == .safe ? .success : .warning)
        let battery = Self.batteryPercent
        LocationService.shared.forCheckIn { [weak self] spot in
            guard let self else { return }
            self.send(c.text(battery: battery, spot: spot, needs: needs, people: people), group: group)
            self.checkInSending = nil
            done?()
        }
    }

    private func setStatus(_ key: String, _ line: String?) {
        DispatchQueue.main.async {
            self.status[key] = line
            let bt = self.ble.nodes, mc = self.mc.nodes, net = self.wifi.nodes
            let all = Set(bt).union(mc).union(net) // a phone linked several ways counts once
            self.bluetoothLinks = bt.count; self.wifiLinks = mc.count + net.count; self.wifiNetworkLinks = net.count
            self.linkedNodes = all
            self.phones = all.count; self.radioLinked = self.lora.connected; self.meshcoreLinked = self.meshcore.connected
            self.relaysLinked = self.nostr?.connected ?? 0
            #if DEBUG
            if CommandLine.arguments.contains("fakeRelays") { self.relaysLinked = 4 } // screenshots of the online state, offline
            #endif
            self.throughTor = self.nostr?.throughTor
            self.bluetooth = self.ble.state
            self.localNetworkDenied = self.wifi.localNetworkDenied
            self.watchTor()
        }
    }

    /// With "Connect through Tor": after 2 minutes without getting through, say so (ConnectionsView). Main thread.
    private func watchTor() {
        guard throughTor == false else { torWaitingSince = nil; torSlow = false; return }
        guard torWaitingSince == nil else { return }
        let since = Date()
        torWaitingSince = since
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.torWaitingSince == since, self.throughTor == false else { return }
            self.torSlow = true
        }
    }

    /// Called by the router while it holds its lock: every transport only queues the packet.
    private func route(_ peer: String, _ p: Packet) {
        let (newlyMine, ownPacket, receipt) = idsLock.withLock {
            (mine.contains(p.id) && !sentIds.contains(p.id), mine.contains(p.id) || myReceipts.contains(p.id), receiptIds.contains(p.id))
        }
        if peer == LoraLink.peer {
            if receipt { return }             // receipts stay off LoRa, where airtime is scarce
            lora.offer(p)
            if !Meshtastic.fits(p) { return } // too long for the radio: not really sent
        }
        else if peer == MeshCoreLink.peer {
            if receipt { return }             // same rules as Meshtastic
            meshcore.offer(p)
            if !MeshCore.fits(p) { return }
        }
        else if peer.hasPrefix(BleLink.prefix) { ble.send(peer, p) }
        else if peer.hasPrefix(MultipeerLink.prefix) { mc.send(peer, p) }
        else if peer.hasPrefix(WifiLink.prefix) { wifi.send(peer, p) }
        // Written on this phone (a message or a receipt): goes up first. "Sent" once a relay accepts it.
        else if peer == NostrLink.peer { nostr.send(p, mine: ownPacket); return }
        if newlyMine { markHandedOff(p.id) }
    }

    /// One of my messages left this phone: to a phone, a radio or the internet relays ("Sent"). Saved on the phone,
    /// so the label survives restarts. Any thread.
    private func markHandedOff(_ id: String) {
        let list: [String]? = idsLock.withLock { mine.contains(id) && sentIds.add(id) ? sentIds.list : nil }
        guard let list else { return }
        UserDefaults.standard.set(list, forKey: "handedOff")
        DispatchQueue.main.async { self.handedOff = Set(list) }
    }

    /// This group's message, else a Public channel message, else another saved group's, else nil (relayed but not
    /// shown); `group` says which group. In someone else's Everyone messages and places, offensive words are masked
    /// (WordFilter); mine stay as written.
    private func read(_ p: Packet, _ k: (active: Keys?, others: [Keys], pub: GroupCrypto?)) -> Message? {
        if let a = k.active, var m = a.group.open(p) { m.group = a.code; return m }
        if let m = k.pub?.open(p) {
            let mine = m.sender == deviceId
            return Message(id: m.id, ts: m.ts, sender: m.sender, name: mine ? m.name : WordFilter.clean(m.name),
                           text: mine ? m.text : WordFilter.clean(m.text), isPublic: true) // photos are group-only (spec)
        }
        for o in k.others { if var m = o.group.open(p) { m.group = o.code; return m } }
        return nil
    }

    /// A delivery receipt of any saved group, or nil.
    private func readReceipt(_ p: Packet, _ k: (active: Keys?, others: [Keys], pub: GroupCrypto?)) -> Message? {
        if let r = k.active?.receipts.open(p) { return r }
        for o in k.others { if let r = o.receipts.open(p) { return r } }
        return nil
    }

    /// A packet seen for the first time: keep it, and show it if a saved group or the Public channel can read it.
    /// Messages of every saved group are confirmed with that group's receipt key and alerted.
    private func onDeliver(_ p: Packet) {
        store.append(p)
        #if DEBUG
        DebugLog.write("received \(p.id) sent-at \(p.ts)")
        #endif
        let k = keySet
        if let m = read(p, k) {
            indexed(p, m.isPublic ? .isPublic : .group)
            let all = [k.active].compactMap { $0 } + k.others
            let receiptKey = m.isPublic ? nil : all.first { $0.code == m.group }?.receipts
            DispatchQueue.main.async {
                let others = !m.isPublic && m.sender != self.deviceId
                if others, let receiptKey { self.ack(m.id, receiptKey) }
                self.add(m)
                guard others, Moderation.visible(m) else { return }
                Notifier.shared.received(m)
            }
        } else if let r = readReceipt(p, k) {
            indexed(p, .group)
            idsLock.withLock { _ = receiptIds.insert(p.id) }
            DispatchQueue.main.async { self.receiptMsgs[r.id] = r; self.deliveries.add(r) }
        } else {
            indexed(p, .unreadable)
        }
        compactIfFull()
    }

    /// Confirms a group message in the next receipt, with that group's key. Messages arriving less than 2 s apart
    /// share one receipt, for at most 10 s (ReceiptBatch). Main thread.
    private func ack(_ id: String, _ key: GroupCrypto) {
        let now = Self.uptimeMs()
        if pendingAcks.isEmpty { firstAck = now; ackTimer(after: ReceiptBatch.quietMs) }
        lastAck = now
        pendingAcks.append((id, key))
    }

    private func ackTimer(after ms: Int64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ms))) { [weak self] in
            guard let self, !self.pendingAcks.isEmpty else { return }
            let now = Self.uptimeMs()
            if ReceiptBatch.due(firstMs: self.firstAck, lastMs: self.lastAck, nowMs: now) { self.flushAcks() }
            else { self.ackTimer(after: Swift.max(10, Swift.min(self.lastAck + ReceiptBatch.quietMs, self.firstAck + ReceiptBatch.maxWaitMs) - now)) }
        }
    }

    private func flushAcks() {
        let batch = pendingAcks
        pendingAcks = []
        var groups: [(key: GroupCrypto, ids: [String])] = []
        for a in batch {
            if let i = groups.firstIndex(where: { $0.key === a.key }) { groups[i].ids.append(a.id) } else { groups.append((a.key, [a.id])) }
        }
        for (rc, ids) in groups {
            for b in Receipt.batches(ids) {
                let id = Packet.newId(mailbox: rc.mailbox), ts = Int64(Date().timeIntervalSince1970 * 1000)
                guard let c = try? rc.seal(id: id, ts: ts, sender: deviceId, name: name, text: Receipt.text(for: b)) else { continue }
                let p = Packet(id: id, ts: ts, ttl: Self.maxTtl, cipher: c)
                idsLock.withLock { _ = receiptIds.insert(id); _ = myReceipts.insert(id) }
                store.append(p)
                indexed(p, .group)
                router.publish(p)
            }
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func uptimeMs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
}

/// Where one of my messages is: still on this phone, given to a phone in range, or confirmed by group members.
enum Delivery: Equatable {
    case waiting, sent, delivered([Reader])
}

extension Engine {
    /// nil for other people's messages, and for my older ones that haven't gone out yet.
    func delivery(of m: Message) -> Delivery? {
        guard m.sender == deviceId else { return nil }
        if !m.isPublic, let r = deliveries.readers[m.id], !r.isEmpty { return .delivered(r) }
        if handedOff.contains(m.id) { return .sent }
        return m.ts >= startedAt ? .waiting : nil
    }
}

#if DEBUG
import UIKit

/// Debug builds only: Library/Application Support/debug.log with receive times and app state changes (no message
/// text), to check from a Mac (`devicectl device copy from ...`) whether messages arrive while the phone is locked.
enum DebugLog {
    private static let lock = NSLock()
    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("debug.log")

    static func start() {
        DispatchQueue.main.async { write(UIApplication.shared.applicationState == .background ? "app started in background" : "app started") }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in write("app in background") }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in write("app in foreground") }
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil) { _ in write("phone locked") }
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { _ in write("phone unlocked") }
    }

    static func write(_ s: String) {
        let line = Data("\(Int64(Date().timeIntervalSince1970 * 1000)) \(s)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
#endif
