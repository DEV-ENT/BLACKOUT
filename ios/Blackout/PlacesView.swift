import SwiftUI
import BlackoutCore

/// A place someone shared on the Public channel.
struct SharedPlace: Identifiable {
    let id: String // message id
    let place: Place
    let by: String
    let ts: Int64
    var mine: Bool { by == "you" }
    var freshness: Freshness { Place.freshness(ts: ts) }
}

extension Engine {
    /// Places shared on the Public channel and not expired (older than 7 days), newest first.
    var places: [SharedPlace] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return messages.reversed().compactMap { m in
            guard m.isPublic, let p = Place.of(m.text), Place.freshness(ts: m.ts, now: now) != .expired else { return nil }
            return SharedPlace(id: m.id, place: p, by: m.sender == deviceId ? "you" : m.name, ts: m.ts)
        }
    }

    /// Hides one of my places on this phone. It can't be taken back from other phones; it expires there after 7 days.
    func removePlace(_ id: String) {
        Moderation.hide(id)
        moderationChanged()
        Nav.shared.toast("Removed from this phone")
    }
}

extension PlaceKind: Identifiable {
    public var id: String { rawValue }
    var symbol: String {
        switch self {
        case .water: return "drop.fill"
        case .shelter: return "house.fill"
        case .charging: return "bolt.fill"
        case .medical: return "cross.case.fill"
        }
    }
}

// MARK: - Places tab

struct PlacesView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var loc = LocationService.shared
    @ObservedObject private var offline = OfflineMap.shared
    @State private var filter: PlaceKind?
    @State private var adding = false
    @State private var finding: SharedPlace?
    @State private var findingPerson: Person?
    @State private var mapCenter: Spot? // the middle of the map on screen, once zoomed in on an area
    @ObservedObject private var nav = Nav.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { t in
            let me = loc.location?.spot
            let shown = Self.sorted(engine.places.filter { filter == nil || $0.place.kind == filter }, from: me)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenTitle(title: "Places", subtitle: "Shared by anyone with DarkProof, nearby or online")
                    PillSwitch(left: "List", right: "Map", isRight: $nav.placesMap)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                if nav.placesMap { map(shown, me: me, now: t.date) } else { list(shown, me: me, now: t.date) }
            }
            .background(Theme.bg.ignoresSafeArea())
        }
        .onAppear { loc.requestPermission(); loc.fix { _ in } }
        .sheet(isPresented: $adding) { AddPlaceSheet(engine: engine) }
        .sheet(item: $finding) { FindSheet(place: $0.place, by: $0.by, ts: $0.ts) }
        .sheet(item: $findingPerson) { FindSheet(person: $0) }
    }

    private func list(_ shown: [SharedPlace], me: Spot?, now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filters
                Button { adding = true } label: { Label("Share a place", systemImage: "plus") }.buttonStyle(PrimaryButton())
                if shown.isEmpty {
                    Card {
                        Text(filter.map { "No \($0.word.lowercased()) places yet" } ?? "No places yet")
                            .scaledFont(20, .bold).foregroundStyle(Theme.text)
                        Text("Know where there is water, shelter, a place to charge phones or medical help? Share it so people nearby can find it.")
                            .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown) { s in
                            PlaceRow(shared: s, me: me, now: now)
                                .contentShape(Rectangle())
                                .onTapGesture { if s.place.spot != nil { finding = s } }
                                .contextMenu {
                                    if s.mine {
                                        Button(role: .destructive) { engine.removePlace(s.id) } label: {
                                            Label("Remove from this phone", systemImage: "trash")
                                        }
                                    }
                                }
                            if s.id != shown.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 76) }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    Text("Greyed places are more than a day old. Places disappear after 7 days. Hold one of yours to remove it from this phone.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
                if me == nil {
                    Text(loc.denied ? "Allow location for DarkProof in Settings to sort places by distance."
                                    : "Finding your position to sort places by distance…")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .refreshable { loc.fix { _ in } }
    }

    /// Street map with places and your group's last check-ins.
    private func map(_ shown: [SharedPlace], me: Spot?, now: Date) -> some View {
        let people = Person.all(in: engine.messages, me: engine.deviceId).filter { $0.spot != nil }
        var pins = shown.compactMap { s -> MapPin? in
            guard let sp = s.place.spot else { return nil }
            return MapPin(id: "place-\(s.id)", lat: sp.lat, lon: sp.lon, title: s.place.kind.word,
                          subtitle: s.place.note.isEmpty ? "By \(s.by), \(ago(s.ts, now))" : s.place.note,
                          symbol: s.place.kind.symbol, letter: "", tint: s.freshness == .fresh ? .white : .gray)
        }
        pins += people.map { p in
            MapPin(id: "person-\(p.id)", lat: p.spot!.lat, lon: p.spot!.lon, title: p.name,
                   subtitle: "\(p.checkIn?.label ?? "Checked in") \(ago(p.spotTs, now))", symbol: nil,
                   letter: String(p.name.prefix(1)).uppercased(),
                   tint: p.checkIn == .help ? UIColor(Theme.help) : p.checkIn == .safe ? UIColor(Theme.safe) : .white)
        }
        var center = me
        if center == nil, case .ready(_, let c, _) = offline.state { center = c }
        return ZStack(alignment: .top) {
            StreetMap(pins: pins, center: center, open: { id in
                if id.hasPrefix("place-") { finding = shown.first { "place-\($0.id)" == id } }
                else { findingPerson = people.first { "person-\($0.id)" == id } }
            }, moved: { c in mapCenter = c })
            VStack(alignment: .leading, spacing: 6) {
                OfflineMapCard(me: me, mapCenter: mapCenter)
                Text("Map data © OpenStreetMap contributors · OpenFreeMap · OpenMapTiles")
                    .scaledFont(11).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.bg.opacity(0.7), in: Capsule())
            }
            .padding(.horizontal, 12).padding(.top, 4)
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", nil)
                ForEach(PlaceKind.allCases) { chip($0.word, $0) }
            }
        }
    }

    private func chip(_ title: String, _ kind: PlaceKind?) -> some View {
        let on = filter == kind
        return Button { filter = kind } label: {
            HStack(spacing: 6) {
                if let kind { Image(systemName: kind.symbol).scaledFont(13, .semibold) }
                Text(title).scaledFont(15, .semibold)
            }
            .foregroundStyle(on ? Color.black : Theme.text)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .background(Capsule().fill(on ? Color.white : Theme.tile))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(title)
    }

    /// Nearest first when my position is known (places without one last, newest first); else newest first.
    static func sorted(_ list: [SharedPlace], from me: Spot?) -> [SharedPlace] {
        guard let me else { return list }
        let located = list.filter { $0.place.spot != nil }
            .sorted { Geo.distance(me, $0.place.spot!) < Geo.distance(me, $1.place.spot!) }
        return located + list.filter { $0.place.spot == nil }
    }
}

/// One shared place: what, details, who and when, and how far. Greyed after a day (spec, "Freshness").
struct PlaceRow: View {
    let shared: SharedPlace
    let me: Spot?
    let now: Date

    var body: some View {
        let p = shared.place
        let fresh = shared.freshness == .fresh
        HStack(spacing: 14) {
            Image(systemName: p.kind.symbol).scaledFont(18, .semibold).foregroundStyle(fresh ? Theme.text : Theme.dim)
                .frame(width: 46, height: 46).background(Circle().fill(Theme.tile))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(p.kind.word).scaledFont(17, .semibold).foregroundStyle(fresh ? Theme.text : Theme.dim)
                    if !fresh { Chip(shared.freshness == .old ? "Over a day old" : "Expired") }
                }
                if !p.note.isEmpty {
                    Text(p.note).scaledFont(15).foregroundStyle(fresh ? Theme.text.opacity(0.85) : Theme.dim).lineLimit(3)
                }
                Text("By \(shared.by) · \(ago(shared.ts, now))").scaledFont(13).foregroundStyle(Theme.faint)
                if let s = p.spot { PlusCodeLabel(spot: s) }
            }
            Spacer(minLength: 8)
            if let s = p.spot {
                if let me {
                    let d = Geo.distance(me, s)
                    if d <= Double(max(15, (me.accuracy ?? 0) + (s.accuracy ?? 0))) {
                        Text("Here").scaledFont(16, .bold).foregroundStyle(Theme.text)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(FindSheet.meters(d)).scaledFont(16, .bold).foregroundStyle(Theme.text)
                            Text(Geo.compassWord(Geo.bearing(me, s))).scaledFont(12).foregroundStyle(Theme.dim)
                        }
                    }
                } else {
                    Image(systemName: "location.north.fill").foregroundStyle(Theme.dim).accessibilityHidden(true)
                }
            } else {
                Text("No position").scaledFont(12).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Share a place

struct AddPlaceSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var loc = LocationService.shared
    @State private var kind = PlaceKind.water
    @State private var note = ""
    @State private var withPosition = true
    @State private var posting = false
    @State private var noFix = false
    @FocusState private var typing: Bool

    private var cleanNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetPage(title: "Share a place") {
            Kicker("What is it?")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(PlaceKind.allCases) { k in
                    let on = k == kind
                    Button { kind = k } label: {
                        VStack(spacing: 8) {
                            Image(systemName: k.symbol).scaledFont(22, .semibold)
                            Text(k.word).scaledFont(16, .semibold)
                        }
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 88)
                        .background(on ? Color.white : Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(k.word)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            InputField(label: "Details", hint: "What, where exactly, and until when.") {
                TextField("", text: $note, prompt: Text("Tap at the school gym, bring bottles").foregroundColor(Theme.faint), axis: .vertical)
                    .lineLimit(1...4).padding(.vertical, 14)
                    .focused($typing)
                    .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false }.fontWeight(.semibold) } }
            }
            Card {
                Toggle(isOn: $withPosition) {
                    Text("Add my current position").scaledFont(17, .bold).foregroundStyle(Theme.text)
                }
                .tint(Theme.safe)
                Text("So people can find it with the compass. Share it only if you are at the place.")
                    .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                if withPosition && loc.denied {
                    Text("Location is off for DarkProof: the place will be shared without a position.")
                        .font(.footnote).foregroundStyle(Theme.help)
                }
            }
            if noFix {
                Text("Couldn't find your position. Add details so people know where it is, or try again outside.")
                    .scaledFont(15, .semibold).foregroundStyle(Theme.help).fixedSize(horizontal: false, vertical: true)
            }
            Button(posting ? "Getting your position…" : "Share with everyone") { post() }
                .buttonStyle(PrimaryButton())
                .disabled(posting || (cleanNote.isEmpty && (!withPosition || loc.denied)))
            Text("Anyone with DarkProof can see it, nearby or online. Once shared it can't be taken back: it disappears after 7 days.")
                .font(.footnote).foregroundStyle(Theme.dim)
        }
        .onAppear { loc.requestPermission() }
    }

    private func post() {
        let n = cleanNote, k = kind
        noFix = false
        guard withPosition else { return share(Place(kind: k, note: n, spot: nil)) }
        posting = true
        loc.fix { spot in
            posting = false
            // A place with neither details nor a position tells nobody anything: don't post it.
            if spot == nil && n.isEmpty { noFix = true; return }
            share(Place(kind: k, note: n, spot: spot))
        }
    }

    private func share(_ p: Place) {
        engine.send(p.text, isPublic: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Nav.shared.toast(engine.queuedToast("the place"))
        dismiss()
    }
}
