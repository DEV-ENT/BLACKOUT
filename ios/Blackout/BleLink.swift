import Foundation
import CoreBluetooth
#if canImport(BlackoutCore) // the Mac test peer (tools/mac-peer) compiles the core into the same module instead
import BlackoutCore
#endif

/// Bluetooth LE link (spec/FORMAT.md, "Bluetooth LE"): the one radio iPhones share with Android phones.
/// This phone is both a peripheral (advertises, GATT server) and a central (scans, connects).
/// All state is touched only on `q`, the queue CoreBluetooth calls back on.
final class BleLink: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    static let prefix = "ble:"
    private static let maxLinks = 6
    private static let retryDelay: TimeInterval = 5

    private final class Link {
        let id: String
        let isCentral: Bool
        let key: UUID                     // CBPeripheral or CBCentral identifier
        var peripheral: CBPeripheral?     // central role
        var central: CBCentral?           // peripheral role
        var rx: CBCharacteristic?
        var chunk = 20
        var open = false                  // setup finished, can send
        var remote: String?
        var up = false                    // known to the router
        var busy = false                  // central role: a write is in flight
        var out: [Data] = []
        var reader = BleProtocol.Reader()
        init(id: String, isCentral: Bool, key: UUID) { self.id = id; self.isCentral = isCentral; self.key = key }
    }

    private let q = DispatchQueue(label: "ble")
    private let service: CBUUID
    private let rxUUID = CBUUID(nsuuid: BleProtocol.rx)
    private let txUUID = CBUUID(nsuuid: BleProtocol.tx)
    private let nodeId: String
    private let router: MeshRouter
    private let onStatus: (String) -> Void
    private var cm: CBCentralManager?
    private var pm: CBPeripheralManager?
    private var tx: CBMutableCharacteristic?
    private var links: [String: Link] = [:]
    private var retryAt: [UUID: Date] = [:]  // peripheral -> earliest time to dial it again
    private var nodeOf: [UUID: String] = [:] // peripheral we dialed -> node id it reported
    private var nextId = 0
    private var note = ""

    init(code: String, nodeId: String, router: MeshRouter, onStatus: @escaping (String) -> Void) {
        service = CBUUID(nsuuid: BleProtocol.serviceUUID(code: code))
        self.nodeId = nodeId; self.router = router; self.onStatus = onStatus
        super.init()
    }

    func start() {
        q.async {
            self.cm = CBCentralManager(delegate: self, queue: self.q)
            self.pm = CBPeripheralManager(delegate: self, queue: self.q)
            self.report()
        }
    }

    /// Called by the router, possibly while it holds its lock, so only queue the work.
    func send(_ peer: String, _ p: Packet) {
        let f = BleProtocol.frame(BleProtocol.packetType, p.encode())
        q.async { if let l = self.links[peer] { self.enqueue(l, f) } }
    }

    // MARK: - Central role: scan and connect

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            c.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            setNote("")
        case .poweredOff: dropAll(central: true); setNote("Bluetooth is off")
        case .unauthorized: setNote("not allowed (Settings > Blackout > Bluetooth)")
        case .unsupported: setNote("not available on this device")
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let k = p.identifier
        guard links.count < Self.maxLinks, !links.values.contains(where: { $0.isCentral && $0.key == k }),
              Date() >= retryAt[k] ?? .distantPast else { return }
        if let n = nodeOf[k], links.values.contains(where: { $0.up && $0.remote == n }) { return } // already linked the other way
        let l = Link(id: newLinkId(), isCentral: true, key: k)
        l.peripheral = p
        links[l.id] = l
        p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([service]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { if let l = link(p) { drop(l) } }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { if let l = link(p) { drop(l) } }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let l = link(p) else { return }
        guard error == nil, let s = p.services?.first(where: { $0.uuid == service }) else { drop(l); return }
        p.discoverCharacteristics([rxUUID, txUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let l = link(p) else { return }
        let cs = s.characteristics ?? []
        guard error == nil, let rx = cs.first(where: { $0.uuid == rxUUID }), let txc = cs.first(where: { $0.uuid == txUUID }) else {
            drop(l); return
        }
        l.rx = rx
        p.setNotifyValue(true, for: txc)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard let l = link(p) else { return }
        guard error == nil, c.isNotifying else { drop(l); return }
        l.chunk = BleProtocol.chunkSize(maxLength: p.maximumWriteValueLength(for: .withResponse))
        l.open = true
        enqueue(l, BleProtocol.hello(nodeId: nodeId))
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard let l = link(p) else { return }
        if error != nil { drop(l); return }
        l.busy = false
        pump(l)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let l = link(p), error == nil, c.uuid == txUUID, let v = c.value else { return }
        onChunk(l, v)
    }

    // MARK: - Peripheral role: GATT server

    func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
        switch m.state {
        case .poweredOn:
            let rx = CBMutableCharacteristic(type: rxUUID, properties: [.write], value: nil, permissions: [.writeable])
            let txc = CBMutableCharacteristic(type: txUUID, properties: [.notify], value: nil, permissions: [])
            let s = CBMutableService(type: service, primary: true)
            s.characteristics = [rx, txc]
            tx = txc
            m.removeAllServices()
            m.add(s) // advertising starts once the service is added
        case .poweredOff: dropAll(central: false)
        default: break
        }
    }

    func peripheralManager(_ m: CBPeripheralManager, didAdd s: CBService, error: Error?) {
        if let error { setNote("GATT service failed: \(error.localizedDescription)"); return }
        m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service]])
    }

    func peripheralManagerDidStartAdvertising(_ m: CBPeripheralManager, error: Error?) {
        if let error { setNote("advertising failed: \(error.localizedDescription)") }
    }

    func peripheralManager(_ m: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        guard c.uuid == txUUID, link(central) == nil, links.count < Self.maxLinks else { return }
        let l = Link(id: newLinkId(), isCentral: false, key: central.identifier)
        l.central = central
        l.chunk = BleProtocol.chunkSize(maxLength: central.maximumUpdateValueLength)
        l.open = true
        links[l.id] = l
        enqueue(l, BleProtocol.hello(nodeId: nodeId))
    }

    func peripheralManager(_ m: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        if let l = link(central) { drop(l) }
    }

    func peripheralManager(_ m: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        let ok = requests.allSatisfy { $0.characteristic.uuid == rxUUID && $0.offset == 0 && link($0.central) != nil }
        m.respond(to: first, withResult: ok ? .success : .writeNotPermitted) // one response for the whole batch
        guard ok else { return }
        for r in requests { if let l = link(r.central), let v = r.value { onChunk(l, v) } }
    }

    func peripheralManagerIsReady(toUpdateSubscribers m: CBPeripheralManager) {
        for l in links.values where !l.isCentral { pump(l) }
    }

    // MARK: - Both roles

    private func link(_ p: CBPeripheral) -> Link? { links.values.first { $0.isCentral && $0.peripheral === p } }
    private func link(_ c: CBCentral) -> Link? { links.values.first { !$0.isCentral && $0.key == c.identifier } }
    private func newLinkId() -> String { nextId += 1; return Self.prefix + String(nextId) }

    private func enqueue(_ l: Link, _ frame: Data) {
        l.out += BleProtocol.chunks(frame, size: l.chunk)
        pump(l)
    }

    /// Central role: one write in flight, the next after its response.
    /// Peripheral role: as many notifications as iOS accepts, then wait for peripheralManagerIsReady.
    private func pump(_ l: Link) {
        guard links[l.id] === l, l.open else { return }
        if l.isCentral {
            guard !l.busy, let c = l.out.first, let p = l.peripheral, let rx = l.rx else { return }
            l.out.removeFirst()
            l.busy = true
            p.writeValue(c, for: rx, type: .withResponse)
        } else {
            guard let m = pm, let central = l.central, let txc = tx else { return }
            while let c = l.out.first, m.updateValue(c, for: txc, onSubscribedCentrals: [central]) { l.out.removeFirst() }
        }
    }

    private func onChunk(_ l: Link, _ chunk: Data) {
        let frames: [(type: UInt8, payload: Data)]
        do { frames = try l.reader.feed(chunk) } catch { drop(l); return }
        for f in frames {
            guard links[l.id] === l else { return }
            switch f.type {
            case BleProtocol.helloType where l.remote == nil:
                guard let r = BleProtocol.parseHello(f.payload), r != nodeId else { drop(l); return }
                hello(l, r)
            case BleProtocol.packetType where l.up:
                if let p = Packet.decode(f.payload) { router.receive(from: l.id, p) }
            default:
                break
            }
        }
    }

    private func hello(_ l: Link, _ remote: String) {
        l.remote = remote
        if l.isCentral { nodeOf[l.key] = remote }
        if let other = links.values.first(where: { $0 !== l && $0.remote == remote }) { // spec: "Duplicate links"
            let keepCentral = BleProtocol.keepMyCentralLink(myId: nodeId, remoteId: remote)
            let loser = other.isCentral == l.isCentral ? other : (l.isCentral == keepCentral ? other : l)
            drop(loser)
            if loser === l { return }
        }
        l.up = true
        router.peerUp(l.id)
        report()
    }

    /// Central role: disconnects. Peripheral role: iOS cannot disconnect a central, so the link is only
    /// forgotten; its further writes get an error and the remote side closes it.
    private func drop(_ l: Link) {
        guard links.removeValue(forKey: l.id) != nil else { return }
        l.open = false
        l.out = []
        if l.isCentral {
            retryAt[l.key] = Date().addingTimeInterval(Self.retryDelay)
            if let p = l.peripheral { cm?.cancelPeripheralConnection(p) }
        }
        if l.up { l.up = false; router.peerDown(l.id) }
        report()
    }

    private func dropAll(central: Bool) { for l in links.values where l.isCentral == central { drop(l) } }
    private func setNote(_ n: String) { note = n; report() }
    private func report() {
        onStatus("Bluetooth LE: \(links.values.filter(\.up).count) link(s)" + (note.isEmpty ? "" : " · \(note)"))
    }
}
