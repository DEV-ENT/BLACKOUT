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

/// A place someone shared on the Public channel: water, shelter, charging or medical help, usually with a position.
/// It is an ordinary Public message, so apps that don't know places (and the Wi-Fi board) show it as text:
/// "💧 Water: tap at the school gym · 📍 45.46420,9.19000 ±12m".
public struct Place: Equatable, Sendable {
    public static let maxNote = 200
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
