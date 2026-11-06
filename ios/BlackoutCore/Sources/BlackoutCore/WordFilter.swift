import Foundation

/// Masks offensive words in other people's Everyone messages and places with bullets (spec/FORMAT.md, "Everyone
/// filter"). Words are masked, not whole messages hidden, so an emergency message with a swear word still gets through.
/// Same list and rules as the Android app's WordFilter.kt; the tests check both against the same examples.
public enum WordFilter {
    /// Space-separated; a trailing * matches any word starting with it. Same text on both apps (SHA-256 in the tests).
    public static let list = "fuck* motherfuck* shit* bitch* bastard* asshole* cunt* dickhead* wanker* twat* whore* slut* porn* blowjob* dildo* cumshot* nigger* nigga* faggot* kike* spic spics wetback* tranny trannies gook gooks retard retards retarded paki pakis cazz* minchi* vaffanculo* fanculo* stronz* coglion* puttana puttane puttaniere troia troie frocio froci ricchion* culatton* porcodio dioporco porcamadonna"

    private static let words = list.split(separator: " ").map(String.init)
    private static let exact = Set(words.filter { !$0.hasSuffix("*") })
    private static let prefixes = words.filter { $0.hasSuffix("*") }.map { String($0.dropLast()) }
    private static let leet: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s"]

    private static func inToken(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "@" || c == "$" }
    private static func fold(_ s: String) -> String { s.folding(options: .diacriticInsensitive, locale: nil) }
    private static func listed(_ k: String) -> Bool { exact.contains(k) || prefixes.contains { k.hasPrefix($0) } }

    /// True if this word is on the list, also when written in capitals, with accents, l33t or stretched ("fuuuck").
    public static func offensive(_ token: String) -> Bool {
        let key = String(fold(token).lowercased().map { leet[$0] ?? $0 }.filter { ("a"..."z").contains($0) })
        if key.isEmpty { return false }
        if listed(key) { return true }
        guard key.range(of: #"(.)\1\1"#, options: .regularExpression) != nil else { return false } // stretched
        return listed(key.replacingOccurrences(of: #"(.)\1{2,}"#, with: "$1$1", options: .regularExpression))
            || listed(key.replacingOccurrences(of: #"(.)\1{2,}"#, with: "$1", options: .regularExpression))
    }

    /// `text` with each offensive word replaced by as many bullets as it has letters.
    public static func clean(_ text: String) -> String {
        var out = "", token = ""
        func flush() {
            if !token.isEmpty {
                out += token.contains(where: \.isLetter) && offensive(token) ? String(repeating: "•", count: fold(token).count) : token
                token = ""
            }
        }
        for c in text {
            if inToken(c) { token.append(c) } else { flush(); out.append(c) }
        }
        flush()
        return out
    }
}
