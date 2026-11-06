import Foundation
import Security

/// Group invites, so nobody has to type a code: a link carrying the group's name and code, shown as a QR code or
/// sent by AirDrop. Format: darkproof://join?name=<name>&code=<code> (spec/FORMAT.md, "Invites"). Anyone who has the
/// link can read the group, like anyone who knows the code.
public enum Invite {
    public static let maxGroupName = 24

    public static func url(name: String, code: String) -> URL {
        var c = URLComponents()
        c.scheme = "darkproof"; c.host = "join"
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "code", value: code)]
        return c.url!
    }

    /// The group name and code in an invite link, or nil if it is not one.
    public static func parse(_ url: URL) -> (name: String, code: String)? {
        guard url.scheme?.lowercased() == "darkproof", url.host?.lowercased() == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              code.count >= 8
        else { return nil }
        let name = items.first { $0.name == "name" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (String((name.isEmpty ? "Group" : name).prefix(maxGroupName)), code)
    }

    /// A random group code with 80 bits of entropy, like "K7QF-2M9X-PA4T-W8RJ". No 0/O or 1/I, to read it aloud safely.
    public static func newCode() -> String {
        let symbols = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // 32 symbols: 5 bits each, and 256 % 32 == 0, so no bias
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("no secure random numbers") // never on a working device; a weak code would be worse
        }
        let chars = bytes.map { symbols[Int($0) % 32] }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }
}

/// A check-in is an ordinary group message that starts with ✅ or 🆘 (spec/FORMAT.md, "Check-ins"), so apps that do
/// not know check-ins still show it as text.
public enum CheckIn: String, Sendable {
    case safe = "✅ I'm safe"
    case help = "🆘 I need help"

    public static func of(_ text: String) -> CheckIn? { text.hasPrefix("✅") ? .safe : text.hasPrefix("🆘") ? .help : nil }
}

/// Someone in your group, known from the messages they sent.
public struct Person: Identifiable, Equatable, Sendable {
    public let id: String // node id
    public var name: String
    public var lastTs: Int64
    public var checkIn: CheckIn?
    public var checkInTs: Int64 = 0

    /// Everyone who wrote in the group (not on the Public channel, not from a Wi-Fi board), people asking for help
    /// first, then the most recently heard.
    public static func all(in messages: [Message], me: String) -> [Person] {
        var byId: [String: Person] = [:]
        for m in messages where !m.isPublic && m.sender != me && !m.sender.hasPrefix("web-") {
            var p = byId[m.sender] ?? Person(id: m.sender, name: m.name, lastTs: m.ts)
            if m.ts >= p.lastTs { p.lastTs = m.ts; p.name = m.name }
            if let c = CheckIn.of(m.text), m.ts >= p.checkInTs { p.checkIn = c; p.checkInTs = m.ts }
            byId[m.sender] = p
        }
        return byId.values.sorted { ($0.checkIn == .help ? 1 : 0, $0.lastTs) > ($1.checkIn == .help ? 1 : 0, $1.lastTs) }
    }
}
