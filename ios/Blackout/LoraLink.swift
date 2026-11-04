import Foundation
import CoreBluetooth
import BlackoutCore

/// BLE client for a Meshtastic LoRa radio, same protocol as the Android LoraLink:
/// subscribe to FromNum, send want_config, then read FromRadio until it is empty; the radio is ready when
/// config_complete_id matches our nonce. Our packets travel as PRIVATE_APP broadcasts (spec/FORMAT.md).
/// All state is touched only on `q`.
final class LoraLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let peer = "lora"
    private static let service = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    private static let toRadioUUID = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    private static let fromRadioUUID = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
    private static let fromNumUUID = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")
    private static let savedKey = "radio"

    private let q = DispatchQueue(label: "lora")
    private let router: MeshRouter
    private let onStatus: (String) -> Void
    private let queue = LoraQueue()
    private let flag = NSLock()
    private var _connected = false
    private var cm: CBCentralManager?
    private var radio: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var nonce: UInt32 = 0
    private var reading = false
    private var writes: [Data] = []
    private var writing = false
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

    /// Called by the router: LoRa only takes recent packets that fit, paced by LoraQueue.
    func offer(_ p: Packet) { queue.offer(p) }

    /// Reports Meshtastic radios in range for 15 seconds. `found` is called on the main thread.
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
        radio = nil; toRadio = nil; fromRadio = nil
        reading = false; writing = false; writes = []
    }

    private func retry(_ why: String) {
        close()
        status("\(why), retrying")
        q.asyncAfter(deadline: .now() + 10) { if self.radio == nil { self.connect() } }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: connect()
        case .poweredOff: close(); status("Bluetooth is off")
        case .unauthorized: status("Bluetooth not allowed (Settings > Blackout)")
        case .unsupported: status("Bluetooth not available on this device")
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        discovered[p.identifier] = p
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Meshtastic radio"
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
        guard error == nil, let s = p.services?.first(where: { $0.uuid == Self.service }) else { retry("not a Meshtastic device"); return }
        p.discoverCharacteristics([Self.toRadioUUID, Self.fromRadioUUID, Self.fromNumUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p === radio else { return }
        let cs = s.characteristics ?? []
        toRadio = cs.first { $0.uuid == Self.toRadioUUID }
        fromRadio = cs.first { $0.uuid == Self.fromRadioUUID }
        guard error == nil, toRadio != nil, fromRadio != nil, let num = cs.first(where: { $0.uuid == Self.fromNumUUID }) else {
            retry("not a Meshtastic device"); return
        }
        p.setNotifyValue(true, for: num) // may trigger iOS pairing: the PIN is shown on the radio
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === radio else { return }
        if error != nil { retry("pairing or PIN failed"); return }
        nonce = UInt32.random(in: 1...1_000_000_000)
        write(Meshtastic.wantConfig(nonce))
        drain()
    }

    // MARK: - Reading and writing

    private func write(_ d: Data) { writes.append(d); nextWrite() }

    private func nextWrite() {
        guard !writing, let p = radio, let c = toRadio, !writes.isEmpty else { return }
        writing = true
        p.writeValue(writes.removeFirst(), for: c, type: .withResponse)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === radio else { return }
        if error != nil { retry("write failed"); return }
        writing = false
        nextWrite()
        drain()
    }

    /// Reads FromRadio until the radio returns an empty value.
    private func drain() {
        guard !reading, let p = radio, let c = fromRadio else { return }
        reading = true
        p.readValue(for: c)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === radio else { return }
        if c.uuid == Self.fromNumUUID { drain(); return } // the radio has something for us
        guard c.uuid == Self.fromRadioUUID else { return }
        reading = false
        if error != nil { retry("pairing or PIN failed"); return }
        guard let v = c.value, !v.isEmpty else { return } // drained
        let m = Meshtastic.parseFromRadio(v)
        if let done = m.configComplete, done == UInt64(nonce), !connected {
            setConnected(true)
            router.peerUp(Self.peer)
            status("radio connected")
        }
        if let raw = m.payload, let pkt = Packet.decode(raw) { router.receive(from: Self.peer, pkt) }
        drain()
    }

    private func pump() {
        guard connected, let p = queue.next() else { return }
        write(Meshtastic.toRadioPacket(p.encode(), packetId: UInt32.random(in: 1...UInt32.max)))
    }

    private func setConnected(_ v: Bool) { flag.lock(); _connected = v; flag.unlock() }
    private func status(_ s: String) { onStatus("LoRa: \(s)") }
}
