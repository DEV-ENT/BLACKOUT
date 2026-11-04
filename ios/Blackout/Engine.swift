import Foundation
import BlackoutCore

/// State shared between the transports and the UI, like the Android MeshEngine.
final class Engine: ObservableObject {
    static let maxTtl = 16
    @Published private(set) var messages: [Message] = []
    @Published private(set) var status: [String: String] = [:] // transport -> status line
    @Published private(set) var phones = 0        // other devices linked directly, each counted once
    @Published private(set) var bluetoothLinks = 0
    @Published private(set) var wifiLinks = 0
    @Published private(set) var radioLinked = false
    @Published private(set) var linkedNodes: Set<String> = [] // node ids linked directly right now
    @Published private(set) var name: String
    let deviceId: String
    private var _crypto: GroupCrypto // the group key; read from the router's thread, so guarded by cryptoLock
    private let cryptoLock = NSLock()
    private var crypto: GroupCrypto { cryptoLock.withLock { _crypto } }
    private let publicCrypto = GroupCrypto(code: GroupCrypto.publicCode)
    private let store = PacketStore()
    private(set) var router: MeshRouter!
    private var ble: BleLink!
    private var mc: MultipeerLink!
    private(set) var lora: LoraLink!
    #if DEBUG
    private(set) var lan: LanTestLink!
    #endif

    init(name: String, code: String) {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "device") { deviceId = id } else {
            deviceId = String(UUID().uuidString.lowercased().prefix(12)) // same shape as Android ids, e.g. 7c0d995b-2c4
            d.set(deviceId, forKey: "device")
        }
        self.name = name
        _crypto = GroupCrypto(code: code)
        router = MeshRouter(send: { [weak self] peer, p in self?.route(peer, p) },
                            deliver: { [weak self] p in self?.onDeliver(p) })
        let all = store.loadAll()
        router.restore(all)
        messages = all.compactMap { read($0) }.sorted { $0.ts < $1.ts }
        mc = MultipeerLink(nodeId: deviceId, router: router) { [weak self] s in self?.setStatus("1-mc", s) }
        ble = BleLink(nodeId: deviceId, router: router) { [weak self] s in self?.setStatus("2-ble", s) }
        lora = LoraLink(router: router) { [weak self] s in self?.setStatus("3-lora", s) }
        #if DEBUG
        lan = LanTestLink(router: router) { [weak self] s in self?.setStatus("4-lan", s) }
        #endif
        #if DEBUG
        DebugLog.start()
        #endif
        mc.start()
        ble.start()
        lora.start()
    }

    var statusLines: [String] { status.keys.sorted().compactMap { status[$0] } }

    /// Switches to another group (or just another name) without restarting the radios: every phone relays every
    /// group anyway. Messages of the old group stay stored and come back on rejoining. Call on the main thread.
    func rejoin(name: String, code: String) {
        let c = GroupCrypto(code: code)
        cryptoLock.withLock { _crypto = c }
        self.name = name
        messages = store.loadAll().compactMap { read($0) }.sorted { $0.ts < $1.ts }
    }

    /// Writes a message from this phone, to the group or to the Public channel. Call on the main thread.
    /// Returns false if it is too long for a LoRa packet (it still travels over Bluetooth and Wi-Fi).
    @discardableResult func send(_ text: String, isPublic: Bool = false) -> Bool {
        let id = Packet.newId(), ts = Int64(Date().timeIntervalSince1970 * 1000)
        guard let c = try? (isPublic ? publicCrypto : crypto).seal(id: id, ts: ts, sender: deviceId, name: name, text: text)
        else { return true }
        let p = Packet(id: id, ts: ts, ttl: Self.maxTtl, cipher: c)
        store.append(p)
        messages.append(Message(id: id, ts: ts, sender: deviceId, name: name, text: text, isPublic: isPublic))
        router.publish(p)
        return Meshtastic.fits(p)
    }

    private func setStatus(_ key: String, _ line: String?) {
        DispatchQueue.main.async {
            self.status[key] = line
            let bt = self.ble.nodes, wifi = self.mc.nodes
            var linked = Set(bt).union(wifi).count
            #if DEBUG
            if self.lan.linked { linked += 1 }
            #endif
            self.bluetoothLinks = bt.count; self.wifiLinks = wifi.count
            self.linkedNodes = Set(bt).union(wifi)
            self.phones = linked; self.radioLinked = self.lora.connected
        }
    }

    /// Called by the router while it holds its lock: every transport only queues the packet.
    private func route(_ peer: String, _ p: Packet) {
        if peer == LoraLink.peer { lora.offer(p) }
        else if peer.hasPrefix(BleLink.prefix) { ble.send(peer, p) }
        else if peer.hasPrefix(MultipeerLink.prefix) { mc.send(peer, p) }
        #if DEBUG
        if peer.hasPrefix(LanTestLink.prefix) { lan.send(peer, p) }
        #endif
    }

    /// This group's message, else a Public channel message, else nil (relayed but not shown).
    private func read(_ p: Packet) -> Message? {
        if let m = crypto.open(p) { return m }
        guard let m = publicCrypto.open(p) else { return nil }
        return Message(id: m.id, ts: m.ts, sender: m.sender, name: m.name, text: m.text, isPublic: true)
    }

    /// A packet seen for the first time: keep it, and show it if it belongs to this group or the Public channel.
    private func onDeliver(_ p: Packet) {
        store.append(p)
        #if DEBUG
        DebugLog.write("received \(p.id) sent-at \(p.ts)")
        #endif
        guard let m = read(p) else { return }
        DispatchQueue.main.async {
            self.messages.append(m)
            self.messages.sort { $0.ts < $1.ts }
        }
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
        write("app started")
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
