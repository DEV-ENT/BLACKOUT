import Foundation
import BlackoutCore

/// What the app knows right now, as plain text for the assistant: the group's check-ins, batteries and positions,
/// shared places and the latest group messages. Sent with each question so answers about "who" and "where" are real.
enum Situation {
    static func text(engine: Engine, groupName: String, me: Spot?, now: Date = Date()) -> String {
        var lines: [String] = []
        let people = Person.all(in: engine.messages, me: engine.deviceId)
        lines.append("Group \"\(groupName)\": \(people.count) other \(people.count == 1 ? "person" : "people") have written; \(engine.phones) phone(s) in range right now.")
        for p in people.prefix(15) {
            var parts: [String] = []
            if let c = p.checkIn { parts.append("\(c == .safe ? "safe" : "NEEDS HELP") (checked in \(ago(p.checkInTs, now)))") }
            else { parts.append("has not checked in") }
            parts.append("last heard \(ago(p.lastTs, now))")
            if let b = p.battery { parts.append("battery \(b)%") }
            if engine.linkedNodes.contains(p.id) { parts.append("phone in range now") }
            if let s = p.spot {
                if let me { parts.append("was \(FindSheet.meters(Geo.distance(me, s))) \(Geo.compassWord(Geo.bearing(me, s)).lowercased()) of you \(ago(p.spotTs, now))") }
                else { parts.append("shared a position \(ago(p.spotTs, now))") }
            }
            lines.append("- \(p.name): " + parts.joined(separator: ", "))
        }
        if let m = engine.myLastCheckIn, let c = CheckIn.of(m.text) {
            lines.append("The user's own last check-in: \(c.label.lowercased()), \(ago(m.ts, now)).")
        } else {
            lines.append("The user has not checked in yet.")
        }

        let places = PlacesView.sorted(engine.places, from: me).prefix(10)
        lines.append(places.isEmpty ? "Shared places: none yet." : "Shared places (nearest first):")
        for s in places {
            var d = ""
            if let sp = s.place.spot, let me { d = ", \(FindSheet.meters(Geo.distance(me, sp))) \(Geo.compassWord(Geo.bearing(me, sp)).lowercased())" }
            let note = s.place.note.isEmpty ? "" : ": \(s.place.note.prefix(120))"
            lines.append("- \(s.place.kind.word)\(note) (by \(s.by), \(ago(s.ts, now))\(d))")
        }

        let recent = engine.messages.filter { !$0.isPublic && CheckIn.of($0.text) == nil }.suffix(8)
        if !recent.isEmpty {
            lines.append("Latest group messages, oldest first:")
            for m in recent {
                let who = m.sender == engine.deviceId ? "The user" : m.name
                let text = m.photo != nil ? "[photo] " + Photo.caption(m.text) : m.text
                lines.append("- \(who), \(ago(m.ts, now)): \(text.prefix(160))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
