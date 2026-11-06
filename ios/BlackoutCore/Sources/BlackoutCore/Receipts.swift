import Foundation

/// A delivery receipt says "I got these messages" (spec/FORMAT.md, "Delivery receipts"). It travels as an ordinary
/// packet sealed with the group's receipt key; its text is the confirmed message ids separated by spaces.
public enum Receipt {
    /// Most ids in one receipt.
    public static let maxIds = 200

    public static func text(for ids: [String]) -> String { ids.joined(separator: " ") }

    /// The message ids a receipt confirms. Anything that isn't 16 lowercase hex characters is skipped.
    public static func ids(in text: String) -> [String] {
        text.split(separator: " ").map(String.init).filter { id in
            id.count == 16 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        }
    }

    /// Splits ids into receipt-sized batches.
    public static func batches(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: maxIds).map { Array(ids[$0..<min($0 + maxIds, ids.count)]) }
    }
}

/// Someone who confirmed getting a message.
public struct Reader: Equatable, Sendable {
    public let id: String   // their device id
    public var name: String
    public var ts: Int64    // their clock when they first confirmed it
    public init(id: String, name: String, ts: Int64) { self.id = id; self.name = name; self.ts = ts }
}

/// Who got which message, built from opened receipts.
public struct Deliveries: Equatable, Sendable {
    /// Message id -> readers, earliest confirmation first.
    public private(set) var readers: [String: [Reader]] = [:]

    public init(_ receipts: [Message] = []) { receipts.forEach { add($0) } }

    /// Adds a receipt (a message opened with the receipt key). A reader counts once per message.
    public mutating func add(_ r: Message) {
        for id in Receipt.ids(in: r.text) {
            var list = readers[id] ?? []
            if let i = list.firstIndex(where: { $0.id == r.sender }) {
                list[i].ts = min(list[i].ts, r.ts)
                list[i].name = r.name
            } else {
                list.append(Reader(id: r.sender, name: r.name, ts: r.ts))
            }
            readers[id] = list.sorted { $0.ts < $1.ts }
        }
    }
}
