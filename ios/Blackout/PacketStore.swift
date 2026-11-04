import Foundation
import BlackoutCore

/// Append-only file of every packet seen, reloaded at startup. The Android app keeps the same list in SQLite.
/// Each record: 4-byte big-endian length, then the encoded packet.
final class PacketStore {
    private let url: URL
    private let lock = NSLock()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("packets.bin")
    }

    func loadAll() -> [Packet] {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: url) else { return [] }
        let b = [UInt8](d)
        var i = 0, out: [Packet] = []
        while i + 4 <= b.count {
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard n > 0, i + 4 + n <= b.count else { break } // a torn last record is ignored
            if let p = Packet.decode(Data(b[(i + 4)..<(i + 4 + n)])) { out.append(p) }
            i += 4 + n
        }
        return out
    }

    func append(_ p: Packet) {
        let e = p.encode()
        let rec = Data([UInt8(e.count >> 24 & 0xFF), UInt8(e.count >> 16 & 0xFF), UInt8(e.count >> 8 & 0xFF), UInt8(e.count & 0xFF)]) + e
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: rec)
        } else {
            try? rec.write(to: url)
        }
    }
}
