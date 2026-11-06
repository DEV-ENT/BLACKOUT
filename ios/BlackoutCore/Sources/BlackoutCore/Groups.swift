import Foundation
import Security

/// Group invites, so nobody has to type a code: a link carrying the group's name and code, shown as a QR code or
/// sent by AirDrop (spec/FORMAT.md, "Invites"). Two forms with the same items: darkproof://join?name=<name>&code=<code>,
/// and https://darkproof.app/join#name=<name>&code=<code>, which also works for people who don't have the app yet.
/// Anyone who has the link can read the group, like anyone who knows the code.
public enum Invite {
    public static let maxGroupName = 24
    public static let minCodeLength = 8
    /// Generated codes: 16 of these, in four groups of four joined by "-".
    public static let symbols = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    public static let webPrefix = "https://darkproof.app/join#"

    /// The app link: opens DarkProof where it is installed (all versions), does nothing elsewhere.
    public static func url(name: String, code: String) -> URL { URL(string: "darkproof://join?" + items(name, code))! }

    /// The web link, for QR codes and sharing: opens DarkProof where it is installed (once darkproof.app serves the
    /// app-link files), else darkproof.app/join, which offers the app link and the downloads. The code stays in the
    /// #fragment, which browsers never send to a server.
    public static func webUrl(name: String, code: String) -> URL { URL(string: webPrefix + items(name, code))! }

    /// The group name and code in an invite link (either form), or nil if it is not one.
    public static func parse(_ url: URL) -> (name: String, code: String)? { parse(url.absoluteString) }

    /// The group name and code in an invite link (either form), or nil if it is not one.
    public static func parse(_ link: String) -> (name: String, code: String)? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let items = match(appLink, s) ?? match(webLink, s) else { return nil }
        var q: [String: String] = [:]
        for kv in items.split(separator: "&", omittingEmptySubsequences: false) {
            guard let i = kv.firstIndex(of: "=") else { continue }
            let k = dec(kv[..<i])
            if q[k] == nil { q[k] = dec(kv[kv.index(after: i)...]) }
        }
        guard let code = q["code"]?.trimmingCharacters(in: .whitespacesAndNewlines), code.count >= minCodeLength else { return nil }
        let name = q["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (String((name.isEmpty ? "Group" : name).prefix(maxGroupName)), code)
    }

    /// The group code someone typed or pasted, cleaned up: the code of an invite link; a generated code typed in lower
    /// case, without dashes or with spaces becomes "K7QF-2M9X-PA4T-W8RJ"; anything else is a custom code, only trimmed.
    /// Use it on new input only, never on saved groups (a custom code that happens to look generated would change).
    public static func normalizeCode(_ input: String) -> String {
        if let i = parse(input) { return i.code }
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = s.unicodeScalars.filter { !separators.contains($0) }.map { $0.value >= 97 && $0.value <= 122 ? Character(Unicode.Scalar($0.value - 32)!) : Character($0) }
        guard bare.count == 16, bare.allSatisfy({ symbols.contains($0) }) else { return s }
        return stride(from: 0, to: 16, by: 4).map { String(bare[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// Whether a code has the generated form (80 bits). Custom codes, especially short ones, can be guessed.
    public static func isGeneratedCode(_ code: String) -> Bool {
        code.range(of: "^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$", options: .regularExpression) != nil
    }

    /// A random group code with 80 bits of entropy, like "K7QF-2M9X-PA4T-W8RJ". No 0/O or 1/I, to read it aloud safely.
    public static func newCode() -> String {
        let symbols = Array(Self.symbols) // 32 symbols: 5 bits each, and 256 % 32 == 0, so no bias
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("no secure random numbers") // never on a working device; a weak code would be worse
        }
        let chars = bytes.map { symbols[Int($0) % 32] }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    // Same patterns as Android (Protocol.kt).
    private static let appLink = try! NSRegularExpression(pattern: "^(?i:darkproof)://(?i:join)\\?(.*)$")
    private static let webLink = try! NSRegularExpression(
        pattern: "^(?i:https?)://(?i:(?:www\\.)?darkproof\\.app)/(?i:join)(?:/|\\.html)?(?:\\?[^#]*)?#(.*)$")
    /// Ignored when reading a typed code: spaces, tabs, line breaks, "-", "_" and other dashes.
    private static let separators = Set(" \u{A0}\t\n\r-_\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}".unicodeScalars)

    private static func match(_ re: NSRegularExpression, _ s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Percent-encodes everything but RFC 3986 unreserved characters (the same bytes as Android).
    private static func items(_ name: String, _ code: String) -> String { "name=\(enc(name))&code=\(enc(code))" }
    private static func enc(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || "-._~".utf8.contains(b) {
                out.append(Character(Unicode.Scalar(b)))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }
    private static func dec(_ s: Substring) -> String { s.removingPercentEncoding ?? String(s) }
}

/// What someone who needs help needs: a small fixed set, written as English words after "🆘 I need help: ".
public enum Need: String, CaseIterable, Sendable {
    case injured, trapped, water, food, medicine, shelter

    /// The word on the wire: "injured", "water", …
    public var word: String { rawValue }
    /// For buttons: "Injured", "Trapped", "Need water", …
    public var label: String {
        switch self {
        case .injured: "Injured"
        case .trapped: "Trapped"
        case .water: "Need water"
        case .food: "Need food"
        case .medicine: "Need medicine"
        case .shelter: "Need shelter"
        }
    }

    /// "injured, water", always in this order.
    public static func text(_ needs: Set<Need>) -> String { allCases.filter(needs.contains).map(\.word).joined(separator: ", ") }

    /// The needs in "injured, water"; unknown words are skipped, so newer apps can add needs.
    public static func parse<S: StringProtocol>(_ list: S) -> Set<Need> {
        Set(list.split(separator: ",", omittingEmptySubsequences: false).compactMap { w in
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return allCases.first { $0.word == t }
        })
    }
}

/// A check-in is an ordinary group message that starts with ✅ or 🆘 (spec/FORMAT.md, "Check-ins"), so apps that do
/// not know check-ins still show it as text. It may say what the sender needs, how many people they speak for, their
/// battery and position: "🆘 I need help: injured, water · 👥 3 · 🔋 23% · 📍 45.46420,9.19000 ±12m".
public enum CheckIn: String, Sendable {
    case safe = "✅ I'm safe"
    case help = "🆘 I need help"

    public static func of(_ text: String) -> CheckIn? { text.hasPrefix("✅") ? .safe : text.hasPrefix("🆘") ? .help : nil }

    /// The message to send, with the phone's battery level and position when known. `needs` are written for `.help`
    /// only; `people` (1–99) for both.
    public func text(battery: Int?, spot: Spot? = nil, needs: Set<Need> = [], people: Int? = nil) -> String {
        var t = rawValue
        if self == .help, !needs.isEmpty { t += ": " + Need.text(needs) }
        if let n = people, (1...99).contains(n) { t += " · 👥 \(n)" }
        if let b = battery, (0...100).contains(b) { t += " · 🔋 \(b)%" }
        if let spot, spot.isValid { t += " · 📍 " + spot.text }
        return t
    }

    /// The position a check-in carries, if any.
    public static func spot(in text: String) -> Spot? { of(text) != nil ? Spot.last(in: text) : nil }

    /// The battery level (0–100) a check-in carries, if any.
    public static func battery(in text: String) -> Int? {
        guard of(text) != nil, let r = text.range(of: "🔋 ", options: .backwards) else { return nil }
        let rest = text[r.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, rest.dropFirst(digits.count).hasPrefix("%"),
              let n = Int(digits), n <= 100 else { return nil }
        return n
    }

    /// The needs a "🆘 I need help: injured, water" check-in lists (empty for anything else).
    public static func needs(in text: String) -> Set<Need> {
        let p = CheckIn.help.rawValue + ": "
        guard text.hasPrefix(p) else { return [] }
        let rest = text.dropFirst(p.count)
        return Need.parse(rest.range(of: " · ").map { rest[..<$0.lowerBound] } ?? rest)
    }

    /// How many people a check-in speaks for (1–99), from its last "👥 N".
    public static func people(in text: String) -> Int? { of(text) != nil ? peopleIn(text) : nil }

    static func peopleIn(_ text: String) -> Int? {
        guard let r = text.range(of: "👥 ", options: .backwards) else { return nil }
        let rest = text[r.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let after = rest.dropFirst(digits.count)
        guard !digits.isEmpty, digits.count <= 2, after.isEmpty || after.hasPrefix(" "), let n = Int(digits), (1...99).contains(n) else { return nil }
        return n
    }
}

/// A check-in for someone else, sent by whoever has news of them: "👤 Grandma is safe" or
/// "👤 Grandma needs help: injured · 👥 2 · 📍 45.46420,9.19000". It does not start with ✅ or 🆘, so no app (old or new)
/// takes it for the sender's own check-in. The reporter is the message's sender; there is no battery level.
public struct Vouch: Equatable, Sendable {
    public static let maxName = 24
    public static let prefix = "👤 "
    private static let safe = " is safe", help = " needs help"

    public let subject: String
    public let status: CheckIn
    public let needs: Set<Need>
    public let people: Int?
    public let spot: Spot?

    public init(subject: String, status: CheckIn, needs: Set<Need> = [], people: Int? = nil, spot: Spot? = nil) {
        self.subject = subject; self.status = status; self.needs = needs; self.people = people; self.spot = spot
    }

    /// The message to send.
    public var text: String {
        let n = Self.cleanName(subject)
        var t = Self.prefix + (n.isEmpty ? "Someone" : n) + (status == .safe ? Self.safe : Self.help)
        if status == .help, !needs.isEmpty { t += ": " + Need.text(needs) }
        if let p = people, (1...99).contains(p) { t += " · 👥 \(p)" }
        if let spot, spot.isValid { t += " · 📍 " + spot.text }
        return t
    }

    /// The report a message makes, if it is one.
    public static func of(_ text: String) -> Vouch? {
        guard text.hasPrefix(prefix) else { return nil }
        let body = text.dropFirst(prefix.count)
        let head = body.range(of: " · ").map { body[..<$0.lowerBound] } ?? body
        let subject: Substring, status: CheckIn
        var needs: Set<Need> = []
        if head.hasSuffix(safe) {
            subject = head.dropLast(safe.count); status = .safe
        } else {
            guard let r = head.range(of: help, options: .backwards) else { return nil }
            let rest = head[r.upperBound...]
            guard rest.isEmpty || rest.hasPrefix(": ") else { return nil }
            subject = head[..<r.lowerBound]; status = .help; needs = Need.parse(rest.dropFirst(rest.isEmpty ? 0 : 2))
        }
        let name = cleanName(String(subject))
        guard !name.isEmpty else { return nil }
        return Vouch(subject: name, status: status, needs: needs, people: CheckIn.peopleIn(text), spot: Spot.last(in: text))
    }

    /// How the People list matches names: case and spacing don't matter ("grandma " is "Grandma").
    public static func key(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// One line, no "·" (it separates the parts), at most maxName characters.
    static func cleanName(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "·", with: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(t.prefix(maxName)).trimmingCharacters(in: .whitespaces)
    }
}

/// "Are you safe?" asked to the whole group ("❓ Is everyone safe?") or one person ("❓ Marco, are you safe?").
/// Apps offer the one-tap answers "I'm safe" and "I need help" (ordinary check-ins) to whoever it is for.
public struct AreYouSafe: Equatable, Sendable {
    public static let everyone = "❓ Is everyone safe?"
    private static let suffix = ", are you safe?"

    /// The person asked, or nil for everyone.
    public let to: String?
    public init(to: String? = nil) { self.to = to }

    public var text: String {
        guard let to else { return Self.everyone }
        let n = Vouch.cleanName(to)
        return n.isEmpty ? Self.everyone : "❓ \(n)\(Self.suffix)"
    }

    /// Whether someone called `myName` should be offered the answers.
    public func isFor(_ myName: String) -> Bool { to == nil || Vouch.key(to!) == Vouch.key(myName) }

    /// The request a message makes, if it is one.
    public static func of(_ text: String) -> AreYouSafe? {
        if text == everyone { return AreYouSafe() }
        guard text.hasPrefix("❓ "), text.hasSuffix(suffix), text.count >= 2 + suffix.count else { return nil }
        let name = Vouch.cleanName(String(text.dropFirst(2).dropLast(suffix.count)))
        return name.isEmpty ? nil : AreYouSafe(to: name)
    }
}

/// Someone in your group, known from the messages they sent, or from someone else's report about them (a Vouch). A
/// report has `reportedBy` set and an id starting with `Person.reportId`, and must be shown as "reported by …", never as
/// the person's own check-in.
public struct Person: Identifiable, Equatable, Sendable {
    /// Ids of report entries: this prefix, then Vouch.key(name). Device ids never look like this.
    public static let reportId = "report:"

    public let id: String // node id, or reportId + name key
    public var name: String
    public var lastTs: Int64
    public var checkIn: CheckIn?
    public var checkInTs: Int64 = 0
    /// Battery level from their latest check-in, if it carried one.
    public var battery: Int? = nil
    /// Where they were at their most recent check-in that carried a position, and when.
    public var spot: Spot? = nil
    public var spotTs: Int64 = 0
    /// From the latest check-in: what they need (help only) and how many people it speaks for.
    public var needs: Set<Need> = []
    public var people: Int? = nil
    /// For a report: who sent it (name and device id). Nil for the person's own check-ins.
    public var reportedBy: String? = nil
    public var reporterId: String? = nil

    public var isReport: Bool { reportedBy != nil }

    /// Everyone who wrote in the group (not on the Public channel, not from a Wi-Fi board), plus the people someone
    /// reported on (by name, latest report wins, including reports this phone sent); people asking for help first, then
    /// the most recently heard. A person's own check-in hides reports about them that are not newer (matched by name).
    public static func all(in messages: [Message], me: String) -> [Person] {
        var byId: [String: Person] = [:]
        var reports: [String: Person] = [:]
        for m in messages where !m.isPublic && !m.sender.hasPrefix("web-") {
            if let v = Vouch.of(m.text) {
                let id = reportId + Vouch.key(v.subject)
                var p = reports[id] ?? Person(id: id, name: v.subject, lastTs: m.ts)
                if m.ts >= p.checkInTs {
                    p.name = v.subject; p.lastTs = max(p.lastTs, m.ts); p.checkIn = v.status; p.checkInTs = m.ts
                    p.needs = v.needs; p.people = v.people; p.reportedBy = m.name; p.reporterId = m.sender
                }
                if let s = v.spot, m.ts >= p.spotTs { p.spot = s; p.spotTs = m.ts }
                reports[id] = p
            }
            guard m.sender != me else { continue }
            var p = byId[m.sender] ?? Person(id: m.sender, name: m.name, lastTs: m.ts)
            if m.ts >= p.lastTs { p.lastTs = m.ts; p.name = m.name }
            if let c = CheckIn.of(m.text), m.ts >= p.checkInTs {
                p.checkIn = c; p.checkInTs = m.ts; p.battery = CheckIn.battery(in: m.text)
                p.needs = CheckIn.needs(in: m.text); p.people = CheckIn.people(in: m.text)
            }
            if let s = CheckIn.spot(in: m.text), m.ts >= p.spotTs { p.spot = s; p.spotTs = m.ts }
            byId[m.sender] = p
        }
        var own: [String: Int64] = [:]
        for p in byId.values where p.checkIn != nil {
            let k = reportId + Vouch.key(p.name)
            own[k] = max(own[k] ?? .min, p.checkInTs)
        }
        let shown = reports.values.filter { (own[$0.id] ?? .min) < $0.checkInTs }
        return (Array(byId.values) + shown).sorted { ($0.checkIn == .help ? 1 : 0, $0.lastTs) > ($1.checkIn == .help ? 1 : 0, $1.lastTs) }
    }
}
