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
    private static let sweepEvery: TimeInterval = 5
    private static let stale: TimeInterval = 5 // at the link limit, a link with no HELLO this old makes room

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
        let createdAt = Date()
        var openedAt: Date?               // when setup finished: the other side's HELLO must come within 10 s
        var out = BleProtocol.Outbox()    // capped: oldest packet frames go first
        var reader = BleProtocol.Reader()
        var gate = BleProtocol.HelloGate() // repeated HELLOs (spec "Restarts")
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

    init(nodeId: String, router: MeshRouter, onStatus: @escaping (String) -> Void) {
        service = CBUUID(nsuuid: BleProtocol.service) // the same for every Blackout device
        self.nodeId = nodeId; self.router = router; self.onStatus = onStatus
        super.init()
    }

    func start() {
        q.async {
            #if os(iOS)
            // Restore identifiers: if iOS closes DarkProof to free memory, it relaunches it in the background when
            // Bluetooth activity arrives (a phone connecting, a message coming in), so this phone keeps relaying.
            // This doesn't apply if the user swipes the app away, or after the phone restarts until it is opened.
            self.cm = CBCentralManager(delegate: self, queue: self.q,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: "darkproof.mesh.central"])
            self.pm = CBPeripheralManager(delegate: self, queue: self.q,
                                          options: [CBPeripheralManagerOptionRestoreIdentifierKey: "darkproof.mesh.peripheral"])
            #else
            self.cm = CBCentralManager(delegate: self, queue: self.q)
            self.pm = CBPeripheralManager(delegate: self, queue: self.q)
            #endif
            self.report()
            self.sweep()
        }
    }

    /// Every 5 s: closes links whose other side sent no HELLO within 10 s of the link opening, and central links still
    /// setting up after 30 s (spec "Limits"). A peripheral-role link is only forgotten: iOS can't disconnect a central,
    /// but this phone stops serving it and it no longer counts toward the link limit.
    private func sweep() {
        let now = Date()
        for l in links.values where l.remote == nil {
            if let o = l.openedAt { if now.timeIntervalSince(o) >= BleProtocol.helloWait { drop(l) } }
            else if now.timeIntervalSince(l.createdAt) >= BleProtocol.setupWait { drop(l) }
        }
        q.asyncAfter(deadline: .now() + Self.sweepEvery) { [weak self] in self?.sweep() }
    }

    /// At the link limit: forgets the oldest link whose other side hasn't sent HELLO after 5 s, if any.
    private func makeRoom() -> Bool {
        let now = Date()
        guard let stale = links.values.filter({ $0.remote == nil && now.timeIntervalSince($0.createdAt) >= Self.stale })
            .min(by: { $0.createdAt < $1.createdAt }) else { return false }
        drop(stale)
        return true
    }

    #if os(iOS)
    /// Relaunched by iOS: pick up the phones we were connected to. Their links start over (services, HELLO), as
    /// after any new connection, once Bluetooth reports power-on. Called before the state update, on `q`.
    func centralManager(_ c: CBCentralManager, willRestoreState state: [String: Any]) {
        let restored = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Self.restoredHook?("central restored \(restored.count) peripheral(s)")
        for p in restored where links.count < Self.maxLinks && !links.values.contains(where: { $0.isCentral && $0.key == p.identifier }) {
            let l = Link(id: newLinkId(), isCentral: true, key: p.identifier)
            l.peripheral = p
            links[l.id] = l
            p.delegate = self // connecting resumes on power-on (centralManagerDidUpdateState): no calls before that
        }
    }

    /// Relaunched by iOS: our GATT service is published again on power-on, as at every start. Centrals that were
    /// subscribed get refused writes for their old link and reconnect, which starts a fresh link.
    func peripheralManager(_ m: CBPeripheralManager, willRestoreState state: [String: Any]) {
        let services = state[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        Self.restoredHook?("peripheral restored \(services.count) service(s)")
    }

    /// Debug logging of restorations (Engine sets it in debug builds).
    static var restoredHook: ((String) -> Void)?
    #endif

    /// Called by the router, possibly while it holds its lock, so only queue the work.
    func send(_ peer: String, _ p: Packet) {
        let f = BleProtocol.frame(BleProtocol.packetType, p.encode())
        q.async { if let l = self.links[peer] { self.enqueue(l, f) } }
    }

    // MARK: - Central role: scan and connect

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        nodeLock.lock(); _state = c.state; nodeLock.unlock()
        switch c.state {
        case .poweredOn:
            c.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            for l in links.values where l.isCentral && !l.open { // restored before power-on: finish connecting
                if let p = l.peripheral { if p.state == .connected { p.discoverServices([service]) } else { c.connect(p) } }
            }
            setNote("")
        case .poweredOff: dropAll(central: true); setNote("Bluetooth is off")
        case .unauthorized: setNote("not allowed (Settings > DarkProof > Bluetooth)")
        case .unsupported: setNote("not available on this device")
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let k = p.identifier
        guard !links.values.contains(where: { $0.isCentral && $0.key == k }), Date() >= retryAt[k] ?? .distantPast else { return }
        if let n = nodeOf[k], links.values.contains(where: { $0.up && $0.remote == n }) { return } // already linked the other way
        guard links.count < Self.maxLinks || makeRoom() else { return }
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
        l.open = true; l.openedAt = Date()
        enqueue(l, BleProtocol.hello(nodeId: nodeId), hello: true)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard let l = link(p) else { return }
        if error != nil { drop(l); return }
        l.busy = false
        pump(l)
    }

    /// The other side published its service again, e.g. its app restarted: start a fresh link.
    func peripheral(_ p: CBPeripheral, didModifyServices invalidated: [CBService]) {
        if let l = link(p), invalidated.contains(where: { $0.uuid == service }) { drop(l) }
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
        guard c.uuid == txUUID, link(central) == nil, links.count < Self.maxLinks || makeRoom() else { return }
        let l = Link(id: newLinkId(), isCentral: false, key: central.identifier)
        l.central = central
        l.chunk = BleProtocol.chunkSize(maxLength: central.maximumUpdateValueLength)
        l.open = true; l.openedAt = l.createdAt
        links[l.id] = l
        enqueue(l, BleProtocol.hello(nodeId: nodeId), hello: true)
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

    /// Queues a frame; the queue is capped (BleProtocol.Outbox): the oldest packet frames go first, HELLO never.
    private func enqueue(_ l: Link, _ frame: Data, hello: Bool = false) {
        l.out.add(frame, hello: hello)
        pump(l)
    }

    /// Central role: one write in flight, the next after its response.
    /// Peripheral role: as many notifications as iOS accepts, then wait for peripheralManagerIsReady.
    private func pump(_ l: Link) {
        guard links[l.id] === l, l.open else { return }
        if l.isCentral {
            guard !l.busy, let p = l.peripheral, let rx = l.rx, let c = l.out.peek(l.chunk) else { return }
            l.out.commit()
            l.busy = true
            p.writeValue(c, for: rx, type: .withResponse)
        } else {
            guard let m = pm, let central = l.central, let txc = tx else { return }
            while let c = l.out.peek(l.chunk), m.updateValue(c, for: txc, onSubscribedCentrals: [central]) { l.out.commit() }
        }
    }

    private func onChunk(_ l: Link, _ chunk: Data) {
        let frames: [(type: UInt8, payload: Data)]
        do { frames = try l.reader.feed(chunk) } catch { drop(l); return }
        for f in frames {
            guard links[l.id] === l else { return }
            switch f.type {
            case BleProtocol.helloType:
                guard let r = BleProtocol.parseHello(f.payload), r != nodeId else { drop(l); return }
                if l.remote == nil { hello(l, r) }
                else if r == l.remote { // spec: "Restarts". The other app restarted on a connection that stayed up.
                    // Answer and send everything stored again, each at most once a minute (no HELLO ping-pong, no
                    // endless re-sync); the receiver ignores what it has.
                    let g = l.gate.repeated(nowMs: Int64(Date().timeIntervalSince1970 * 1000), queueEmpty: l.out.isEmpty)
                    if g.answer { enqueue(l, BleProtocol.hello(nodeId: nodeId), hello: true) }
                    if g.resync && l.up { router.peerUp(l.id) }
                } else { drop(l); return }
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
        l.out.clear()
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
        let up = links.values.filter(\.up)
        nodeLock.lock(); _nodes = up.compactMap(\.remote); nodeLock.unlock()
        onStatus("Bluetooth LE: \(up.count) link(s)" + (note.isEmpty ? "" : " · \(note)"))
    }

    /// Node ids of the devices linked right now. Safe from any thread.
    var nodes: [String] { nodeLock.lock(); defer { nodeLock.unlock() }; return _nodes }
    /// Bluetooth on this phone: on, off, not allowed for DarkProof, missing (Simulator). Safe from any thread.
    var state: CBManagerState { nodeLock.lock(); defer { nodeLock.unlock() }; return _state }
    private let nodeLock = NSLock()
    private var _nodes: [String] = []
    private var _state = CBManagerState.unknown
}
