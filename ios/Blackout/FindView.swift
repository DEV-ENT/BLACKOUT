import SwiftUI
import CoreLocation
import BlackoutCore

/// Compass to a friend or a shared place: an arrow toward it, and how far it is.
/// GPS and the compass work without internet.
struct FindSheet: View {
    let title: String
    let name: String          // card title
    let target: Spot
    let ts: Int64             // when the position was shared
    let detail: (String) -> String // "Where Marco checked in 2 min ago": gets the age
    var chip: (String, Color)? = nil
    var tint = Theme.text
    @ObservedObject private var loc = LocationService.shared

    init(person: Person) {
        title = "Find \(person.name)"; name = person.name; target = person.spot ?? Spot(lat: 0, lon: 0); ts = person.spotTs
        detail = person.isReport ? { "Where \(person.reportedBy ?? "someone") said \(person.name) was, \($0)" }
                                 : { "Where \(person.name) checked in \($0)" }
        chip = person.checkIn.map { ($0.label, $0.color) }; tint = person.checkIn?.color ?? Theme.text
    }

    init(place: Place, by: String, ts: Int64) {
        title = place.kind.word; name = place.note.isEmpty ? place.kind.word : place.note
        target = place.spot ?? Spot(lat: 0, lon: 0); self.ts = ts
        detail = { "Shared by \(by) \($0)" }
    }

    var body: some View {
        SheetPage(title: title) {
            TimelineView(.periodic(from: .now, by: 30)) { t in
                content(target, now: t.date)
            }
        }
        .onAppear { loc.watch() }
        .onDisappear { loc.stop() }
    }

    @ViewBuilder private func content(_ target: Spot, now: Date) -> some View {
        let me = loc.location?.spot
        VStack(spacing: 18) {
            dial(target, me)
            if let me {
                let d = Geo.distance(me, target), b = Geo.bearing(me, target)
                let fuzz = Double((me.accuracy ?? 0) + (target.accuracy ?? 0))
                if d <= max(15, fuzz) {
                    Text("Very close").scaledFont(44, .heavy).foregroundStyle(Theme.text)
                    Text("Within about \(Self.meters(max(15, fuzz))). Look around or call out.")
                        .scaledFont(16).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                } else {
                    Text(Self.meters(d)).scaledFont(56, .heavy).tracking(-1).foregroundStyle(Theme.text)
                    Text("\(Geo.compassWord(b)) of you").scaledFont(17, .semibold).foregroundStyle(Theme.dim)
                }
            } else if loc.denied {
                Text("Allow location to see how far").scaledFont(20, .bold).foregroundStyle(Theme.text)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(GhostButton())
            } else {
                Text("Finding your position…").scaledFont(20, .bold).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(name).scaledFont(18, .bold).foregroundStyle(Theme.text)
                Spacer()
                if let chip { Chip(chip.0, chip.1) }
            }
            Text(detail(ago(ts, now)) + (target.accuracy.map { ", within about \(Self.meters(Double($0)))" } ?? "") + ".")
                .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            PlusCodeLabel(spot: target)
            if loc.heading == nil && me != nil {
                Text("This phone has no compass right now, so the arrow assumes the top of the phone points north.")
                    .font(.footnote).foregroundStyle(Theme.faint)
            }
        }
        Button { openInMaps(target) } label: { Label("Open in Maps", systemImage: "map") }.buttonStyle(SecondaryButton())
        Text("Maps work offline only for areas you downloaded in Apple Maps before the blackout.")
            .font(.footnote).foregroundStyle(Theme.dim)
    }

    /// Arrow toward the target, turned by the phone's heading so it points the right way in your hand.
    private func dial(_ target: Spot, _ me: Spot?) -> some View {
        let angle = me.map { Geo.bearing($0, target) - (loc.heading ?? 0) } ?? 0
        return ZStack {
            Circle().fill(Theme.card)
            Circle().stroke(Theme.line, lineWidth: 2).padding(14)
            CompassArrow(angle: angle, color: me == nil ? Theme.decor : tint)
        }
        .frame(width: 240, height: 240)
        .accessibilityElement()
        .accessibilityLabel(me.map { "\(name) is \(Geo.compassWord(Geo.bearing($0, target))) of you" } ?? "Finding your position")
    }

    private func openInMaps(_ s: Spot) {
        var c = URLComponents(string: "maps://")!
        c.queryItems = [.init(name: "ll", value: "\(s.lat),\(s.lon)"), .init(name: "q", value: name)]
        if let url = c.url { UIApplication.shared.open(url) }
    }

    /// "40 m", "250 m", "1.2 km", "12 km".
    static func meters(_ d: Double) -> String {
        if d < 100 { return "\(Int((d / 5).rounded() * 5)) m" }
        if d < 1000 { return "\(Int((d / 10).rounded() * 10)) m" }
        if d < 10_000 { return String(format: "%.1f km", d / 1000) }
        return "\(Int((d / 1000).rounded())) km"
    }
}

/// The arrow of the compass. It turns the short way: from 350° to 10° it moves 20°, not 340° backwards.
struct CompassArrow: View {
    let angle: Double
    let color: Color
    @State private var shown: Double?

    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 96, weight: .bold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(shown ?? angle))
            .onAppear { shown = angle }
            .onChange(of: angle) { new in
                let from = shown ?? new
                var delta = (new - from).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                withAnimation(Theme.lowPower ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { shown = from + delta }
            }
            .accessibilityHidden(true)
    }
}
