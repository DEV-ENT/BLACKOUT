import Foundation

/// What a shared place offers (spec/FORMAT.md, "Places").
public enum PlaceKind: String, CaseIterable, Sendable {
    case water = "💧 Water"
    case shelter = "🏠 Shelter"
    case charging = "🔌 Charging"
    case medical = "🏥 Medical"

    /// "Water", "Shelter", …
    public var word: String { String(rawValue.split(separator: " ", maxSplits: 1)[1]) }
}

/// How current a shared place is (Place.freshness).
public enum Freshness: Sendable {
    /// Shared in the last 24 hours (or by a phone whose clock is ahead).
    case fresh
    /// Older than 24 hours: shown greyed.
    case old
    /// Older than 7 days: hidden.
    case expired
}

/// A place someone shared on the Public channel: water, shelter, charging or medical help, usually with a position.
/// It is an ordinary Public message, so apps that don't know places (and the Wi-Fi board) show it as text:
/// "💧 Water: tap at the school gym · 📍 45.46420,9.19000 ±12m".
public struct Place: Equatable, Sendable {
    public static let maxNote = 200
    public static let oldAfterMs: Int64 = 24 * 3_600_000
    public static let expiredAfterMs: Int64 = 7 * 24 * 3_600_000

    /// How current a place shared at `ts` (ms since 1970) is at `now`, so both apps grey and hide places alike.
    public static func freshness(ts: Int64, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Freshness {
        if now - ts > expiredAfterMs { return .expired }
        if now - ts > oldAfterMs { return .old }
        return .fresh
    }
    public let kind: PlaceKind
    public let note: String
    public let spot: Spot?

    public init(kind: PlaceKind, note: String, spot: Spot?) { self.kind = kind; self.note = note; self.spot = spot }

    /// The message to post.
    public var text: String {
        let n = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNote))
        var t = n.isEmpty ? kind.rawValue : "\(kind.rawValue): \(n)"
        if let spot, spot.isValid { t += " · 📍 " + spot.text }
        return t
    }

    /// The place a message describes, if it is one.
    public static func of(_ text: String) -> Place? {
        guard let kind = PlaceKind.allCases.first(where: { text.hasPrefix($0.rawValue) }) else { return nil }
        var rest = text.dropFirst(kind.rawValue.count)
        guard rest.isEmpty || rest.hasPrefix(":") || rest.hasPrefix(" · ") else { return nil } // e.g. "💧 Waterfall" is not one
        let spot = Spot.last(in: text)
        if spot != nil, let r = rest.range(of: " · 📍 ", options: .backwards) { rest = rest[..<r.lowerBound] }
        if rest.hasPrefix(":") { rest = rest.dropFirst() }
        return Place(kind: kind, note: rest.trimmingCharacters(in: .whitespaces), spot: spot)
    }
}
