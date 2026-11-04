import Foundation

/// Hand-encoded subset of the Meshtastic protocol (ToRadio/FromRadio), same as the Android Meshtastic.kt.
/// Field numbers come from the Meshtastic protobufs (mesh.proto, portnums.proto).
public enum Meshtastic {
    public static let payloadMax = 233
    static let privateApp: UInt64 = 256   // PortNum.PRIVATE_APP
    static let broadcast: UInt32 = 0xFFFF_FFFF
    static let hopLimit: UInt64 = 3

    public static func fits(_ p: Packet) -> Bool { p.encode().count <= payloadMax }

    public static func varint(_ value: UInt64) -> Data {
        var out = Data(), x = value
        while x >= 0x80 { out.append(UInt8(x & 0x7F) | 0x80); x >>= 7 }
        out.append(UInt8(x))
        return out
    }
    private static func varintField(_ f: Int, _ v: UInt64) -> Data { varint(UInt64(f << 3)) + varint(v) }
    private static func bytesField(_ f: Int, _ b: Data) -> Data { varint(UInt64(f << 3 | 2)) + varint(UInt64(b.count)) + b }
    private static func fixed32Field(_ f: Int, _ v: UInt32) -> Data {
        varint(UInt64(f << 3 | 5)) + Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }

    /// ToRadio.want_config_id: asks the radio to send its configuration, ending with config_complete_id == nonce.
    public static func wantConfig(_ nonce: UInt32) -> Data { varintField(3, UInt64(nonce)) }

    /// ToRadio.packet: a broadcast MeshPacket on channel 0 carrying `payload` on PRIVATE_APP.
    public static func toRadioPacket(_ payload: Data, packetId: UInt32) -> Data {
        let data = varintField(1, privateApp) + bytesField(2, payload)                         // Data
        let packet = fixed32Field(2, broadcast) + bytesField(4, data) + fixed32Field(6, packetId) + varintField(9, hopLimit) // MeshPacket
        return bytesField(1, packet)
    }

    private enum Malformed: Error { case truncated }

    /// Calls `on(field, varintValue, bytes)` for each field; bytes is non-nil for length-delimited fields.
    private static func walk(_ b: [UInt8], _ on: (Int, UInt64, [UInt8]?) -> Void) throws {
        var i = 0
        func readVarint() throws -> UInt64 {
            var r: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < b.count, shift < 64 else { throw Malformed.truncated }
                let x = b[i]; i += 1
                r |= UInt64(x & 0x7F) << shift
                if x & 0x80 == 0 { return r }
                shift += 7
            }
        }
        while i < b.count {
            let tag = try readVarint(), field = Int(tag >> 3)
            switch tag & 7 {
            case 0: on(field, try readVarint(), nil)
            case 1: guard i + 8 <= b.count else { throw Malformed.truncated }; i += 8
            case 2:
                let n = Int(try readVarint())
                guard n >= 0, i + n <= b.count else { throw Malformed.truncated }
                on(field, 0, Array(b[i..<(i + n)])); i += n
            case 5: guard i + 4 <= b.count else { throw Malformed.truncated }; i += 4
            default: return
            }
        }
    }

    public static func fieldBytes(_ b: Data, _ field: Int) -> Data? {
        var r: Data?
        try? walk([UInt8](b)) { f, _, x in if f == field, let x { r = Data(x) } }
        return r
    }

    public struct FromRadio: Equatable {
        public let payload: Data?           // our packet, if this was a PRIVATE_APP MeshPacket
        public let configComplete: UInt64?  // config_complete_id
    }

    public static func parseFromRadio(_ b: Data) -> FromRadio {
        var payload: Data?, done: UInt64?
        do {
            try walk([UInt8](b)) { f, v, x in
                if f == 7 { done = v }
                if f == 2, let x, let decoded = fieldBytes(Data(x), 4) { // FromRadio.packet -> MeshPacket.decoded
                    var port: UInt64 = 0
                    try? walk([UInt8](decoded)) { pf, pv, _ in if pf == 1 { port = pv } }
                    if port == privateApp { payload = fieldBytes(decoded, 2) }
                }
            }
        } catch { return FromRadio(payload: nil, configComplete: nil) }
        return FromRadio(payload: payload, configComplete: done)
    }
}

/// LoRa has very little bandwidth: only recent messages that fit, one at a time. Same rules as the Android LoraQueue.
public final class LoraQueue: @unchecked Sendable { // state guarded by `lock`
    public static let maxAgeMs: Int64 = 30 * 60_000
    public static let intervalMs: Int64 = 20_000
    public static let maxQueue = 20
    private let now: () -> Int64
    private let lock = NSLock()
    private var q: [Packet] = []
    private var sent: [String] = []
    private var sentSet = Set<String>()
    private var last: Int64 = 0

    public init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.now = now }

    public func offer(_ p: Packet) {
        lock.lock(); defer { lock.unlock() }
        guard p.ts >= now() - Self.maxAgeMs, p.encode().count <= Meshtastic.payloadMax, sentSet.insert(p.id).inserted else { return }
        sent.append(p.id)
        if sent.count > 1000 { sentSet.remove(sent.removeFirst()) }
        if q.count >= Self.maxQueue { q.removeFirst() }
        q.append(p)
    }

    public func next() -> Packet? {
        lock.lock(); defer { lock.unlock() }
        guard !q.isEmpty, now() - last >= Self.intervalMs else { return nil }
        last = now()
        return q.removeFirst()
    }
}
