import Foundation
import CoreBluetooth
import BlackoutCore

/// Bluetooth LE client for a MeshCore radio, same protocol as the Android MeshCoreLink (spec/FORMAT.md, "LoRa via
/// MeshCore"): check the firmware, start, find or add the #darkproof channel, then send and receive DarkProof packets
/// as flooded channel data. Commands go one at a time, each waiting for its reply. All state is touched only on `q`.
final class MeshCoreLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let peer = "meshcore"
    private static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // the phone writes here
    private static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // the radio notifies here
    private static let savedKey = "meshcore"
    private let q = DispatchQueue(label: "meshcore")
    private let router: MeshRouter
    private let onStatus: (String) -> Void
    private let queue = LoraQueue(maxBytes: MeshCore.payloadMax)
    private let flag = NSLock()
    private var _connected = false
    private var cm: CBCentralManager?
    private var radio: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var rx: CBCharacteristic?
    private var commands: [(Data, (Data?) -> Void)] = []
    private var waiting: ((Data?) -> Void)?
    private var timeout: DispatchWorkItem?
    private var slot = -1
    private var syncing = false
    private var onFound: ((UUID, String) -> Void)?
    private var timer: DispatchSourceTimer?

    /// Safe to read from any thread.
    var connected: Bool { flag.lock(); defer { flag.unlock() }; return _connected }

    init(router: MeshRouter, onStatus: @escaping (String) -> Void) {
        self.router = router; self.onStatus = onStatus
        super.init()
    }

    func start() {
        q.async {
            self.cm = CBCentralManager(delegate: self, queue: self.q)
            let t = DispatchSource.makeTimerSource(queue: self.q) // sends at most one queued packet per interval
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.pump() }
            t.resume()
            self.timer = t
            self.status(UserDefaults.standard.string(forKey: Self.savedKey) == nil ? "no radio" : "connecting…")
        }
    }

    /// Called by the router: only recent packets that fit, paced by LoraQueue.
    func offer(_ p: Packet) { queue.offer(p) }

    /// Reports MeshCore radios in range for 15 seconds. `found` is called on the main thread.
    func scan(found: @escaping (UUID, String) -> Void) {
        q.async {
            guard let cm = self.cm, cm.state == .poweredOn else { self.status("Bluetooth is not available"); return }
            self.onFound = found
            cm.scanForPeripherals(withServices: [Self.service])
            self.q.asyncAfter(deadline: .now() + 15) { cm.stopScan(); self.onFound = nil }
        }
    }

    func select(_ id: UUID) {
        q.async {
            UserDefaults.standard.set(id.uuidString, forKey: Self.savedKey)
            self.close()
            self.connect()
        }
    }

    // MARK: - Connection

    private func connect() {
        guard let cm, cm.state == .poweredOn, let saved = UserDefaults.standard.string(forKey: Self.savedKey),
              let id = UUID(uuidString: saved) else { return }
        guard let p = discovered[id] ?? cm.retrievePeripherals(withIdentifiers: [id]).first else {
            status("radio not found, search again"); return
        }
        radio = p
        p.delegate = self
        cm.connect(p) // iOS keeps trying until the radio is in range
        status("connecting…")
    }

    private func close() {
        let was = connected
        setConnected(false)
        if was { router.peerDown(Self.peer) }
        if let p = radio { cm?.cancelPeripheralConnection(p) }
        radio = nil; rx = nil; slot = -1; syncing = false
        commands = []; waiting = nil; timeout?.cancel(); timeout = nil
    }

    private func retry(_ why: String) {
        close()
        status("\(why), retrying")
        q.asyncAfter(deadline: .now() + 10) { if self.radio == nil { self.connect() } }
    }

    private func stop(_ why: String) { close(); status(why) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: connect()
        case .poweredOff: close(); status("Bluetooth is off")
        case .unauthorized: status("Bluetooth not allowed (Settings > DarkProof)")
        case .unsupported: status("Bluetooth not available on this device")
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        discovered[p.identifier] = p
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "MeshCore radio"
        if let found = onFound { DispatchQueue.main.async { found(p.identifier, name) } }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === radio else { return }
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if p === radio { retry("radio unreachable") }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if p === radio { retry("radio unreachable") }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === radio else { return }
        guard error == nil, let s = p.services?.first(where: { $0.uuid == Self.service }) else { retry("not a MeshCore radio"); return }
        p.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p === radio else { return }
        let cs = s.characteristics ?? []
        rx = cs.first { $0.uuid == Self.rxUUID }
        guard error == nil, rx != nil, let tx = cs.first(where: { $0.uuid == Self.txUUID }) else { retry("not a MeshCore radio"); return }
        p.setNotifyValue(true, for: tx) // may trigger iOS pairing: the PIN is shown on the radio, often 123456
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === radio else { return }
        if error != nil { retry("pairing or PIN failed"); return }
        setUp()
    }

    // MARK: - Commands

    /// Queues a command; `reply` gets its reply frame, or nil if none came within 5 s.
    private func command(_ frame: Data, _ reply: @escaping (Data?) -> Void = { _ in }) {
        commands.append((frame, reply)); next()
    }

    private func next() {
        guard waiting == nil, !commands.isEmpty, let p = radio, let c = rx else { return }
        let (frame, reply) = commands.removeFirst()
        waiting = reply
        p.writeValue(frame, for: c, type: .withResponse)
        let t = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = t
        q.asyncAfter(deadline: .now() + 5, execute: t)
    }

    private func finish(_ f: Data?) {
        guard let r = waiting else { return }
        waiting = nil; timeout?.cancel(); timeout = nil
        r(f); next()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === radio else { return }
        if error != nil { finish(nil) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === radio, c.uuid == Self.txUUID, error == nil, let f = c.value, !f.isEmpty else { return }
        if MeshCore.isPush(f) { if f.first == MeshCore.msgWaiting { sync() }; return }
        finish(f)
    }

    // MARK: - Setup, receiving, sending

    private func setUp() {
        command(MeshCore.deviceQuery()) { [weak self] f in
            guard let self else { return }
            guard let info = f.flatMap(MeshCore.deviceInfo) else { return self.retry("not a MeshCore radio") }
            guard info.firmware >= MeshCore.minFirmware else { return self.stop("firmware too old: update the radio to MeshCore 1.15 or newer") }
            self.command(MeshCore.appStart()) { s in
                guard s?.first == MeshCore.selfInfo else { return self.retry("no answer from the radio") }
                self.findSlot(0, info.channels, -1)
            }
        }
    }

    private func findSlot(_ i: Int, _ count: Int, _ firstEmpty: Int) {
        if i >= count {
            guard firstEmpty >= 0 else { return stop("no free channel on the radio: remove one in the MeshCore app") }
            command(MeshCore.setChannel(firstEmpty)) { [weak self] f in
                if f?.first == MeshCore.ok { self?.ready(firstEmpty) } else { self?.retry("couldn't add the #darkproof channel") }
            }
            return
        }
        command(MeshCore.getChannel(i)) { [weak self] f in
            let s = f.flatMap(MeshCore.slot)
            if let s, s.isOurs { self?.ready(s.idx); return }
            self?.findSlot(i + 1, count, firstEmpty < 0 && (s == nil || s!.isEmpty) ? i : firstEmpty)
        }
    }

    private func ready(_ idx: Int) {
        slot = idx
        setConnected(true)
        router.peerUp(Self.peer)
        status("radio connected")
        sync()
    }

    /// Fetches queued frames until the radio says there are no more.
    private func sync() {
        guard !syncing, slot >= 0 else { return }
        syncing = true
        command(MeshCore.syncNext()) { [weak self] f in
            guard let self else { return }
            self.syncing = false
            guard let f, f.first != MeshCore.noMore else { return }
            if let raw = MeshCore.packet(f, slot: self.slot), let p = Packet.decode(raw) { self.router.receive(from: Self.peer, p) }
            self.sync()
        }
    }

    private func pump() {
        guard connected, waiting == nil, commands.isEmpty, let p = queue.next(), let f = MeshCore.sendData(slot, p.encode()) else { return }
        command(f)
    }

    private func setConnected(_ v: Bool) { flag.lock(); _connected = v; flag.unlock() }
    private func status(_ s: String) { onStatus("MeshCore: \(s)") }
}
