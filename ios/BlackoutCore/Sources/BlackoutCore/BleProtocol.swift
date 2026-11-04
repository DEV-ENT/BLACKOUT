import Foundation
import CryptoKit

/// Bluetooth LE link protocol (spec/FORMAT.md, "Bluetooth LE"). Pure logic, same as the Android BleProtocol.kt.
public enum BleProtocol {
    public static let rx = UUID(uuidString: "33826aba-0bb0-4dfe-9c1a-86e48726ed62")!  // central writes
    public static let tx = UUID(uuidString: "94eb2c34-0e66-4bea-864c-d02a7694a3d5")!  // peripheral notifies
    public static let version: UInt8 = 1
    public static let helloType: UInt8 = 1
    public static let packetType: UInt8 = 2
    static let maxNodeId = 64

    public enum StreamError: Error { case badType(UInt8), badLength(Int) }

    /// First 16 bytes of SHA-256("ble:" + NFC(code)), so only the same group finds each other.
    public static func serviceUUID(code: String) -> UUID {
        let h = [UInt8](SHA256.hash(data: Data(("ble:" + code.precomposedStringWithCanonicalMapping).utf8)))
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }

    public static func frame(_ type: UInt8, _ payload: Data) -> Data {
        Data([type, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) + payload
    }

    public static func hello(nodeId: String) -> Data { frame(helloType, Data([version]) + Data(nodeId.utf8)) }

    /// Node id from a HELLO payload, or nil if the version or id is not acceptable.
    public static func parseHello(_ payload: Data) -> String? {
        let b = [UInt8](payload)
        guard b.count >= 2, b[0] == version, b.count - 1 <= maxNodeId, b.dropFirst().allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
        return String(decoding: b.dropFirst(), as: UTF8.self)
    }

    /// Largest chunk for a link: what the stack allows, but never above 512 (maximum attribute value length).
    public static func chunkSize(maxLength: Int) -> Int { min(max(maxLength, 20), 512) }

    /// Pieces of at most `size` bytes, each sent as one write or one notification.
    public static func chunks(_ frame: Data, size: Int) -> [Data] {
        stride(from: 0, to: frame.count, by: size).map { frame.subdata(in: $0..<min($0 + size, frame.count)) }
    }

    /// Of two links to the same node, true means keep the one where this device is the central.
    public static func keepMyCentralLink(myId: String, remoteId: String) -> Bool {
        Array(myId.utf8).lexicographicallyPrecedes(Array(remoteId.utf8))
    }

    /// Rebuilds frames from chunks. Throws on a malformed stream: the caller disconnects.
    public struct Reader {
        private var buf: [UInt8] = []
        public init() {}
        public mutating func feed(_ chunk: Data) throws -> [(type: UInt8, payload: Data)] {
            buf += chunk
            var out: [(type: UInt8, payload: Data)] = []
            var i = 0
            while buf.count - i >= 3 {
                let type = buf[i], len = Int(buf[i + 1]) << 8 | Int(buf[i + 2])
                let max: Int
                switch type {
                case helloType: max = 1 + maxNodeId
                case packetType: max = Packet.headerSize + Packet.maxCipher
                default: throw StreamError.badType(type)
                }
                guard (1...max).contains(len) else { throw StreamError.badLength(len) }
                guard buf.count - i - 3 >= len else { break }
                out.append((type, Data(buf[(i + 3)..<(i + 3 + len)])))
                i += 3 + len
            }
            buf.removeFirst(i)
            return out
        }
    }
}
