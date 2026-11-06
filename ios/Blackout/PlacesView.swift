import SwiftUI
import BlackoutCore

/// A place someone shared on the Public channel.
struct SharedPlace: Identifiable {
    let id: String // message id
    let place: Place
    let by: String
    let ts: Int64
}

extension Engine {
    /// Places shared on the Public channel, newest first.
    var places: [SharedPlace] {
        messages.reversed().compactMap { m in
            guard m.isPublic, let p = Place.of(m.text) else { return nil }
            return SharedPlace(id: m.id, place: p, by: m.sender == deviceId ? "you" : m.name, ts: m.ts)
        }
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
    @State private var showMap = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { t in
            let me = loc.location?.spot
            let shown = Self.sorted(engine.places.filter { filter == nil || $0.place.kind == filter }, from: me)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenTitle(title: "Places", subtitle: "Shared by anyone with DarkProof, nearby or online")
                    PillSwitch(left: "List", right: "Map", isRight: $showMap)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                if showMap { map(shown, me: me, now: t.date) } else { list(shown, me: me, now: t.date) }
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
                            .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                        Text("Know where there is water, shelter, a place to charge phones or medical help? Share it so people nearby can find it.")
                            .font(.system(size: 15)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown) { s in
                            PlaceRow(shared: s, me: me, now: now)
                                .contentShape(Rectangle())
                                .onTapGesture { if s.place.spot != nil { finding = s } }
                            if s.id != shown.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 76) }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                          symbol: s.place.kind.symbol, letter: "", tint: .white)
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
            StreetMap(pins: pins, center: center) { id in
                if id.hasPrefix("place-") { finding = shown.first { "place-\($0.id)" == id } }
                else { findingPerson = people.first { "person-\($0.id)" == id } }
            }
            VStack(alignment: .leading, spacing: 6) {
                OfflineMapCard(me: me)
                Text("Map data © OpenStreetMap contributors · OpenFreeMap · OpenMapTiles")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
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
                if let kind { Image(systemName: kind.symbol).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(on ? Color.black : Theme.text)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .background(Capsule().fill(on ? Color.white : Theme.tile))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Nearest first when my position is known (places without one last, newest first); else newest first.
    static func sorted(_ list: [SharedPlace], from me: Spot?) -> [SharedPlace] {
        guard let me else { return list }
        let located = list.filter { $0.place.spot != nil }
            .sorted { Geo.distance(me, $0.place.spot!) < Geo.distance(me, $1.place.spot!) }
        return located + list.filter { $0.place.spot == nil }
    }
}

/// One shared place: what, details, who and when, and how far.
struct PlaceRow: View {
    let shared: SharedPlace
    let me: Spot?
    let now: Date

    var body: some View {
        let p = shared.place
        HStack(spacing: 14) {
            Image(systemName: p.kind.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 46, height: 46).background(Circle().fill(Theme.tile))
            VStack(alignment: .leading, spacing: 3) {
                Text(p.kind.word).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                if !p.note.isEmpty {
                    Text(p.note).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(3)
                }
                Text("By \(shared.by) · \(ago(shared.ts, now))").font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            if let s = p.spot {
                if let me {
                    let d = Geo.distance(me, s)
                    if d <= Double(max(15, (me.accuracy ?? 0) + (s.accuracy ?? 0))) {
                        Text("Here").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(FindSheet.meters(d)).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                            Text(Geo.compassWord(Geo.bearing(me, s))).font(.system(size: 12)).foregroundStyle(Theme.dim)
                        }
                    }
                } else {
                    Image(systemName: "location.north.fill").foregroundStyle(Theme.dim)
                }
            } else {
                Text("No position").font(.system(size: 12)).foregroundStyle(Theme.faint)
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
    @FocusState private var typing: Bool

    var body: some View {
        SheetPage(title: "Share a place") {
            Kicker("What is it?")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(PlaceKind.allCases) { k in
                    let on = k == kind
                    Button { kind = k } label: {
                        VStack(spacing: 8) {
                            Image(systemName: k.symbol).font(.system(size: 22, weight: .semibold))
                            Text(k.word).font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 88)
                        .background(on ? Color.white : Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(PressScale())
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
                    Text("Add my current position").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                }
                .tint(Theme.safe)
                Text("So people can find it with the compass. Share it only if you are at the place.")
                    .font(.system(size: 15)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                if withPosition && loc.denied {
                    Text("Location is off for DarkProof: the place will be shared without a position.")
                        .font(.footnote).foregroundStyle(Theme.help)
                }
            }
            Button(posting ? "Getting your position…" : "Share with everyone") { post() }
                .buttonStyle(PrimaryButton())
                .disabled(posting || (note.trimmingCharacters(in: .whitespaces).isEmpty && !withPosition))
            Text("Anyone with DarkProof can see it, nearby or online. It stays on phones and relays for up to 7 days.")
                .font(.footnote).foregroundStyle(Theme.dim)
        }
        .onAppear { loc.requestPermission() }
    }

    private func post() {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kind
        guard withPosition else { return share(Place(kind: k, note: n, spot: nil)) }
        posting = true
        loc.fix { spot in share(Place(kind: k, note: n, spot: spot)) }
    }

    private func share(_ p: Place) {
        engine.send(p.text, isPublic: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        posting = false
        dismiss()
    }
}
