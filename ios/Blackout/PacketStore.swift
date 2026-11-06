import Foundation
import BlackoutCore

/// Append-only file of every packet seen, read back piece by piece (never the whole file at once). The Android app
/// keeps the same list in SQLite. Each record: 4-byte big-endian length, then the encoded packet. Its size is kept
/// under the store cap by Engine (StoreCap), which removes records with `remove`.
final class PacketStore {
    private let url: URL
    private let lock = NSLock() // appends and rewrites; reading needs no lock (a rewrite replaces the file atomically)
    private static let piece = 1 << 20

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("packets.bin")
    }

    /// Calls `body` with every stored packet, in the order they were stored, reading 1 MB at a time. Any thread; may
    /// run while packets are appended (a torn last record is ignored).
    func forEach(_ body: (Packet) -> Void) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        Self.records(h) { _, p in if let p { body(p) } }
    }

    /// Removes the packets with these ids by writing the others to a new file that then replaces this one, under the
    /// lock, so packets appended meanwhile are kept.
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let tmp = url.appendingPathExtension("new")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil), let out = try? FileHandle(forWritingTo: tmp) else { return }
        var pending = Data()
        Self.records(h) { record, p in
            guard let p, !ids.contains(p.id) else { return } // unreadable records go too
            pending.append(record)
            if pending.count >= Self.piece { try? out.write(contentsOf: pending); pending = Data() }
        }
        try? out.write(contentsOf: pending)
        try? out.close()
        if Foundation.rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
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

    /// Each whole record (length prefix included) and its packet, or nil if it doesn't decode. Stops at a bad length.
    private static func records(_ h: FileHandle, _ body: (Data, Packet?) -> Void) {
        var buf: [UInt8] = []
        while let more = try? h.read(upToCount: piece), !more.isEmpty {
            buf.append(contentsOf: more)
            var i = 0
            while i + 4 <= buf.count {
                let n = Int(buf[i]) << 24 | Int(buf[i + 1]) << 16 | Int(buf[i + 2]) << 8 | Int(buf[i + 3])
                guard n > 0, n <= Packet.headerSize + Packet.maxCipher else { return } // damaged: ignore the rest
                guard i + 4 + n <= buf.count else { break }                             // the rest comes with the next piece
                let record = Data(buf[i..<(i + 4 + n)])
                body(record, Packet.decode(record.dropFirst(4)))
                i += 4 + n
            }
            buf.removeFirst(i)
        }
    }
}
