import Foundation
import BlackoutCore

/// People the user blocked and messages the user reported: both are hidden everywhere (chats, places, people, alerts).
/// Kept only on this phone. Reports also go to the internet relays when there is internet. Same rules as Android.
enum Moderation {
    private static let d = UserDefaults.standard

    /// Blocked sender ids and the name they had.
    static var blocked: [String: String] { d.dictionary(forKey: "blocked") as? [String: String] ?? [:] }
    static func block(_ id: String, name: String) { var b = blocked; b[id] = name; d.set(b, forKey: "blocked") }
    static func unblock(_ id: String) { var b = blocked; b.removeValue(forKey: id); d.set(b, forKey: "blocked") }

    /// Ids of messages the user reported or hid.
    static var hidden: Set<String> { Set(d.stringArray(forKey: "hidden") ?? []) }
    static func hide(_ id: String) { d.set(Array((d.stringArray(forKey: "hidden") ?? []) + [id]).suffix(2_000), forKey: "hidden") }

    /// Reports waiting to go to the internet relays.
    static var pendingReports: [String] { d.stringArray(forKey: "reports") ?? [] }
    static func report(_ id: String) {
        hide(id)
        d.set(Array((pendingReports + [id]).suffix(200)), forKey: "reports")
    }
    static func reportsSent(_ ids: [String]) { d.set(pendingReports.filter { !ids.contains($0) }, forKey: "reports") }

    static func visible(_ m: Message) -> Bool { blocked[m.sender] == nil && !hidden.contains(m.id) }
}
