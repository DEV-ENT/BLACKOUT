import Foundation
import BlackoutCore

/// State shared between the transports and the UI, like the Android MeshEngine.
final class Engine: ObservableObject {
    static let maxTtl = 16
    @Published private(set) var messages: [Message] = []
    @Published private(set) var status: [String: String] = [:] // transport -> status line
    let deviceId: String
    let name: String
    private let crypto: GroupCrypto
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
        crypto = GroupCrypto(code: code)
        router = MeshRouter(send: { [weak self] peer, p in self?.route(peer, p) },
                            deliver: { [weak self] p in self?.onDeliver(p) })
        let all = store.loadAll()
        router.restore(all)
        messages = all.compactMap { crypto.open($0) }.sorted { $0.ts < $1.ts }
        mc = MultipeerLink(code: code, nodeId: deviceId, router: router) { [weak self] s in self?.setStatus("1-mc", s) }
        ble = BleLink(code: code, nodeId: deviceId, router: router) { [weak self] s in self?.setStatus("2-ble", s) }
        lora = LoraLink(router: router) { [weak self] s in self?.setStatus("3-lora", s) }
        #if DEBUG
        lan = LanTestLink(router: router) { [weak self] s in self?.setStatus("4-lan", s) }
        #endif
        mc.start()
        ble.start()
        lora.start()
    }

    var statusLines: [String] { status.keys.sorted().compactMap { status[$0] } }

    /// Writes a message from this phone. Call on the main thread.
    /// Returns false if it is too long for a LoRa packet (it still travels over Bluetooth and Wi-Fi).
    @discardableResult func send(_ text: String) -> Bool {
        let id = Packet.newId(), ts = Int64(Date().timeIntervalSince1970 * 1000)
        guard let c = try? crypto.seal(id: id, ts: ts, sender: deviceId, name: name, text: text) else { return true }
        let p = Packet(id: id, ts: ts, ttl: Self.maxTtl, cipher: c)
        store.append(p)
        messages.append(Message(id: id, ts: ts, sender: deviceId, name: name, text: text))
        router.publish(p)
        return Meshtastic.fits(p)
    }

    private func setStatus(_ key: String, _ line: String?) { DispatchQueue.main.async { self.status[key] = line } }

    /// Called by the router while it holds its lock: every transport only queues the packet.
    private func route(_ peer: String, _ p: Packet) {
        if peer == LoraLink.peer { lora.offer(p) }
        else if peer.hasPrefix(BleLink.prefix) { ble.send(peer, p) }
        else if peer.hasPrefix(MultipeerLink.prefix) { mc.send(peer, p) }
        #if DEBUG
        if peer.hasPrefix(LanTestLink.prefix) { lan.send(peer, p) }
        #endif
    }

    /// A packet seen for the first time: keep it, and show it if it belongs to this group.
    private func onDeliver(_ p: Packet) {
        store.append(p)
        guard let m = crypto.open(p) else { return }
        DispatchQueue.main.async {
            self.messages.append(m)
            self.messages.sort { $0.ts < $1.ts }
        }
    }
}
