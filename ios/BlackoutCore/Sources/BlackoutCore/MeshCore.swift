import Foundation
import CryptoKit

/// The MeshCore companion-radio protocol, as far as DarkProof uses it (spec/FORMAT.md, "LoRa via MeshCore").
/// Same frames as the Android app's MeshCore.kt; the Bluetooth part is MeshCoreLink in the app.
public enum MeshCore {
    public static let payloadMax = 163           // channel data that every firmware from 1.15 delivers
    public static let minFirmware = 11           // FIRMWARE_VER_CODE of 1.15, the first with channel data
    public static let dataType: UInt16 = 0xFF44  // development range FF00-FFFF
    public static let channelName = "#darkproof"
    /// First 16 bytes of SHA-256("#darkproof"), as MeshCore derives hashtag channel keys.
    public static let channelKey = Data(SHA256.hash(data: Data(channelName.utf8)).prefix(16))

    public static let ok: UInt8 = 0x00, selfInfo: UInt8 = 0x05, noMore: UInt8 = 0x0A, deviceInfoCode: UInt8 = 0x0D
    public static let channelInfo: UInt8 = 0x12, channelData: UInt8 = 0x1B, msgWaiting: UInt8 = 0x83

    public static func fits(_ p: Packet) -> Bool { p.encode().count <= payloadMax }

    public static func deviceQuery() -> Data { Data([0x16, 0x03]) }
    public static func appStart() -> Data { Data([0x01]) + Data(count: 7) + Data("DarkProof".utf8) }
    public static func getChannel(_ idx: Int) -> Data { Data([0x1F, UInt8(idx)]) }
    public static func setChannel(_ idx: Int) -> Data {
        var name = Data(channelName.utf8); name.append(Data(count: 32 - name.count))
        return Data([0x20, UInt8(idx)]) + name + channelKey
    }
    public static func syncNext() -> Data { Data([0x0A]) }
    /// Channel data, flooded (path FF), data type 0xFF44 little-endian. nil if the packet is too long.
    public static func sendData(_ idx: Int, _ packet: Data) -> Data? {
        guard packet.count <= payloadMax else { return nil }
        return Data([0x3E, UInt8(idx), 0xFF, UInt8(dataType & 0xFF), UInt8(dataType >> 8)]) + packet
    }

    /// Replies have codes below 0x80; pushes (sent by the radio on its own) at 0x80 and above.
    public static func isPush(_ f: Data) -> Bool { (f.first ?? 0) >= 0x80 }

    public struct DeviceInfo: Equatable { public let firmware: Int; public let channels: Int }
    public static func deviceInfo(_ f: Data) -> DeviceInfo? {
        let b = [UInt8](f)
        guard b.count >= 4, b[0] == deviceInfoCode else { return nil }
        return DeviceInfo(firmware: Int(b[1]), channels: Int(b[3]))
    }

    /// A channel slot. `isOurs` when it holds the DarkProof key; `isEmpty` when unused.
    public struct Slot: Equatable {
        public let idx: Int; public let name: String; public let key: Data
        public var isOurs: Bool { key == MeshCore.channelKey }
        public var isEmpty: Bool { name.isEmpty && key.allSatisfy { $0 == 0 } }
    }
    public static func slot(_ f: Data) -> Slot? {
        let b = [UInt8](f)
        guard b.count >= 2 + 32 + 16, b[0] == channelInfo else { return nil }
        let name = String(decoding: b[2..<34].prefix { $0 != 0 }, as: UTF8.self)
        return Slot(idx: Int(b[1]), name: name, key: Data(b[34..<50]))
    }

    /// The DarkProof packet in a channel-data frame on `slot`, or nil for anything else.
    public static func packet(_ f: Data, slot: Int) -> Data? {
        let b = [UInt8](f)
        guard b.count >= 9, b[0] == channelData, Int(b[4]) == slot else { return nil }
        let type = UInt16(b[6]) | UInt16(b[7]) << 8, len = Int(b[8])
        guard type == dataType, b.count >= 9 + len else { return nil }
        return Data(b[9..<(9 + len)])
    }
}
