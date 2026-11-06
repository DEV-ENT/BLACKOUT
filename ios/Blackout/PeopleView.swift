import SwiftUI
import BlackoutCore

// MARK: - Model

extension CheckIn {
    var label: String { self == .safe ? "Safe" : "Needs help" }
    var color: Color { self == .safe ? Theme.safe : Theme.help }
}

extension Engine {
    /// This phone's battery level, or nil when unknown (the Simulator has none).
    static var batteryPercent: Int? {
        #if DEBUG
        if let v = UserDefaults.standard.object(forKey: "debugBattery") as? Int { return v } // simctl spawn ... defaults write
        #endif
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    /// Your own most recent check-in in this group.
    var myLastCheckIn: Message? {
        messages.last { !$0.isPublic && $0.sender == deviceId && CheckIn.of($0.text) != nil }
    }
}

/// "just now", "5 min ago", "2 h ago", "3 d ago".
func ago(_ ts: Int64, _ now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince1970 - Double(ts) / 1000))
    switch s {
    case ..<60: return "just now"
    case ..<3600: return "\(s / 60) min ago"
    case ..<86_400: return "\(s / 3600) h ago"
    default: return "\(s / 86_400) d ago"
    }
}

// MARK: - People tab

struct PeopleView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var nav = Nav.shared
    @AppStorage("groupName") private var groupName = "My group"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { t in
            let people = Person.all(in: engine.messages, me: engine.deviceId)
            let nearby = people.filter { engine.linkedNodes.contains($0.id) }.count
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        ScreenTitle(title: "People", subtitle: people.isEmpty ? groupName :
                            "\(groupName) · \(people.count) \(people.count == 1 ? "person" : "people") · \(nearby) nearby")
                        Spacer()
                        Button { nav.sheet = .settings } label: { RoundIcon(symbol: "gearshape.fill") }.accessibilityLabel("Settings")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            BigCheckIn(checkIn: .safe, sending: engine.checkInSending == .safe) {
                                let e = engine
                                e.checkIn(.safe) { nav.toast(e.queuedToast("“I'm safe”")) }
                            }
                            BigCheckIn(checkIn: .help, sending: engine.checkInSending == .help) { nav.sheet = .help }
                        }
                        .disabled(engine.checkInSending != nil)
                        LastCheckIn(engine: engine, now: t.date).padding(.horizontal, 4)
                    }
                    SetupProblemCard(engine: engine)
                    if engine.reach == .none && engine.setupProblem == nil { ConnectionHelp(engine: engine) }
                    if people.isEmpty {
                        NoPeopleCard(groupName: groupName) { nav.sheet = .invite }
                    } else {
                        PeopleList(people: people, engine: engine, now: t.date)
                    }
                    VStack(spacing: 10) {
                        Button { nav.sheet = .askSafe } label: { Label("Ask “Are you safe?”", systemImage: "questionmark.bubble.fill") }
                            .buttonStyle(SecondaryButton())
                        Button { nav.sheet = .vouch } label: { Label("Check in for someone", systemImage: "person.crop.circle.badge.checkmark") }
                            .buttonStyle(SecondaryButton())
                        if !people.isEmpty {
                            Button { nav.sheet = .invite } label: { Label("Invite friends", systemImage: "qrcode") }
                                .buttonStyle(SecondaryButton())
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
        }
    }
}

/// Big green "I'm safe" or red "I need help" tile, in the logo's shape.
struct BigCheckIn: View {
    let checkIn: CheckIn
    var sending = false
    let action: () -> Void

    var body: some View {
        let safe = checkIn == .safe
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: safe ? "checkmark.shield.fill" : "sos").scaledFont(30, .bold)
                Text(sending ? "Sending…" : safe ? "I'm safe" : "I need help").scaledFont(21, .heavy)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(safe ? Color.black : .white)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .bottomLeading).padding(18)
            .background(VaultShape(cut: 28, radius: 32, small: 6).fill(checkIn.color))
            .contentShape(VaultShape(cut: 28, radius: 32, small: 6))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(sending ? "Sending" : safe ? "I'm safe" : "I need help")
        .accessibilityHint(safe ? "Tells your group you're safe" : "Asks your group for help")
    }
}

/// "Your last check-in: safe, 12 min ago."
struct LastCheckIn: View {
    @ObservedObject var engine: Engine
    let now: Date

    var body: some View {
        if engine.checkInSending != nil {
            Text("Getting your position, then sending…").scaledFont(14, .semibold).foregroundStyle(Theme.text)
        } else if let m = engine.myLastCheckIn, let c = CheckIn.of(m.text) {
            Text("Your last check-in: \(c.label.lowercased()), \(ago(m.ts, now)).").scaledFont(14).foregroundStyle(Theme.dim)
        } else {
            Text("One tap tells your group how you are.").scaledFont(14).foregroundStyle(Theme.dim)
        }
    }
}

/// Shown while nobody from the group has written yet.
struct NoPeopleCard: View {
    let groupName: String
    let invite: () -> Void

    var body: some View {
        Card {
            Text("No one from \(groupName) yet").scaledFont(20, .bold).foregroundStyle(Theme.text)
            Text("Invite friends with a QR code, then keep DarkProof open near each other. People show up here once they write.")
                .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            Button(action: invite) { Label("Invite friends", systemImage: "qrcode") }.buttonStyle(PrimaryButton())
        }
    }
}

/// People in one card, divided by hairlines.
struct PeopleList: View {
    let people: [Person]
    @ObservedObject var engine: Engine
    let now: Date
    @State private var finding: Person?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(people) { p in
                PersonRow(person: p, inRange: engine.linkedNodes.contains(p.id), byMe: p.reporterId == engine.deviceId, now: now) { finding = p }
                if p.id != people.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 76) }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .sheet(item: $finding) { FindSheet(person: $0) }
    }
}

struct PersonRow: View {
    let person: Person
    let inRange: Bool
    var byMe = false
    let now: Date
    var find: () -> Void = {} // opens the compass, for people who shared their position

    private var status: (String, Color) {
        guard let c = person.checkIn else { return ("Last heard \(ago(person.lastTs, now))", Theme.dim) }
        if person.isReport {
            let by = byMe ? "by you" : "by \(person.reportedBy ?? "someone")"
            return ("\(c.label) (reported \(by)) · \(ago(person.checkInTs, now))", c.color)
        }
        return ("\(c.label) · \(ago(person.checkInTs, now))", c.color)
    }

    var body: some View {
        let s = status
        let extra = needsText(person.checkIn == .help ? person.needs : [], people: person.people)
        HStack(spacing: 14) {
            Group {
                if person.isReport {
                    Image(systemName: "person.fill").scaledFont(18, .bold).foregroundStyle(Theme.dim)
                        .frame(width: 46, height: 46).background(Circle().fill(Theme.tile))
                        .overlay(Circle().stroke(person.checkIn?.color ?? .clear, style: StrokeStyle(lineWidth: 2, dash: [4, 3])).padding(-3))
                } else {
                    Text(String(person.name.prefix(1)).uppercased()).scaledFont(18, .bold).foregroundStyle(Theme.text)
                        .frame(width: 46, height: 46).background(Circle().fill(Theme.tile))
                        .overlay(Circle().stroke(person.checkIn?.color ?? .clear, lineWidth: 2.5).padding(-3))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).scaledFont(17, .semibold).foregroundStyle(Theme.text).lineLimit(1)
                Text(s.0).scaledFont(14, .medium).foregroundStyle(s.1).fixedSize(horizontal: false, vertical: true)
                if !extra.isEmpty { Text(extra).scaledFont(14, .semibold).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if inRange { Chip("Nearby") }
                if let b = person.battery { BatteryLabel(percent: b) }
            }
            if person.spot != nil {
                Button(action: find) { RoundIcon(symbol: "location.north.fill") }
                    .accessibilityLabel("Find \(person.name)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { if person.spot != nil { find() } }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Find \(person.name)") { if person.spot != nil { find() } }
    }
}

/// Battery level from someone's check-in. Red at 20% or less: their phone may soon go off.
struct BatteryLabel: View {
    let percent: Int

    var body: some View {
        let low = percent <= 20
        HStack(spacing: 4) {
            Image(systemName: percent <= 10 ? "battery.0percent" : percent <= 35 ? "battery.25percent" :
                    percent <= 60 ? "battery.50percent" : percent <= 85 ? "battery.75percent" : "battery.100percent")
            Text("\(percent)%")
        }
        .scaledFont(13, .semibold)
        .foregroundStyle(low ? Theme.help : Theme.dim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent) percent")
    }
}

// MARK: - Connection help

/// Shown while nothing carries messages yet (no phone, relay or radio): what to check.
struct ConnectionHelp: View {
    @ObservedObject var engine: Engine

    var body: some View {
        Card {
            Text("No one in range yet").scaledFont(20, .bold).foregroundStyle(Theme.text)
            tip("iphone.radiowaves.left.and.right",
                "Open DarkProof on both phones and stay within about 10–50 m. Walls cut the range: try outside or by a window.")
            tip("wifi", "On the same Wi-Fi or hotspot, phones also connect with no internet.")
            tip("point.3.connected.trianglepath.dotted",
                "Farther away? Messages hop through any phone with DarkProof in between. For kilometers, pair a LoRa radio.")
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.text).frame(width: 22).accessibilityHidden(true)
            Text(text).scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings

struct GroupSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("groupName") private var groupName = "My group"
    @AppStorage("code") private var code = ""
    @AppStorage("name") private var myName = ""
    @State private var nameDraft = ""
    @State private var groupDraft = ""
    @State private var blocked: [String: String] = [:]
    @AppStorage(LocationService.shareKey) private var shareLocation = false
    @ObservedObject private var loc = LocationService.shared
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        SheetPage(title: "Settings") {
            Card {
                InputField(label: "Your name", hint: "Shown next to your messages.") {
                    TextField("", text: $nameDraft).submitLabel(.done)
                }
                InputField(label: "Group name", hint: "Only on this phone. Each person can name it as they like.") {
                    TextField("", text: $groupDraft, prompt: Text(groupName).foregroundColor(Theme.faint)).submitLabel(.done)
                }
                Button("Save") { save() }
                    .buttonStyle(PrimaryButton())
                    .disabled(clean(nameDraft, 20).isEmpty)
            }
            Card { FingerprintView(code: code) }
            GroupsCard(engine: engine)
            Card {
                HStack {
                    Text("Notifications").scaledFont(17, .bold).foregroundStyle(Theme.text)
                    Spacer()
                    switch notifier.status {
                    case .authorized, .provisional, .ephemeral: Chip("On", Theme.safe)
                    case .denied: Chip("Off")
                    default: EmptyView()
                    }
                }
                Text("Alerts when your groups write or check in, and always when someone needs help. In the background iOS keeps only Bluetooth running, so alerts then come from phones nearby. Made on your phone: no internet needed.")
                    .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                if notifier.status == .notDetermined {
                    Button("Turn on notifications") { notifier.requestPermission() }.buttonStyle(GhostButton())
                } else if notifier.status == .denied {
                    OpenSettingsButton()
                }
            }
            .onAppear { notifier.refresh() }
            Card {
                Toggle(isOn: $shareLocation) {
                    Text("Share my location in check-ins").scaledFont(17, .bold).foregroundStyle(Theme.text)
                }
                .tint(Theme.safe)
                Text("When you tap I'm safe or I need help, your group also sees where you are, and can find you with a compass. It works without internet. Only your group can read your check-ins.")
                    .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                if shareLocation && loc.denied {
                    Text("Location is off for DarkProof. Allow it in Settings, or your check-ins go out without it.")
                        .font(.footnote).foregroundStyle(Theme.help)
                    OpenSettingsButton()
                }
            }
            .onChange(of: shareLocation) { on in if on { LocationService.shared.requestPermission() } }
            Card {
                Text("Practice and shortcuts").scaledFont(17, .bold).foregroundStyle(Theme.text)
                HStack(spacing: 10) {
                    Button("Practice asking for help") { open(.practice) }.buttonStyle(GhostButton())
                    Button("Shortcut") { open(.shortcut) }.buttonStyle(GhostButton())
                }
                Button("Show the Get ready list") { UserDefaults.standard.set(false, forKey: "hideGetReady"); Nav.shared.toast("It's on Home") }
                    .buttonStyle(GhostButton())
            }
            if !blocked.isEmpty {
                Card {
                    Text("Blocked people").scaledFont(17, .bold).foregroundStyle(Theme.text)
                    Text("Their messages, places and check-ins are hidden on this phone.").scaledFont(15).foregroundStyle(Theme.dim)
                    ForEach(blocked.sorted(by: { $0.value < $1.value }), id: \.key) { id, name in
                        HStack {
                            Text(name).scaledFont(17, .semibold).foregroundStyle(Theme.text)
                            Spacer()
                            Button("Unblock") { Moderation.unblock(id); blocked = Moderation.blocked; engine.moderationChanged() }
                                .buttonStyle(GhostButton()).accessibilityLabel("Unblock \(name)")
                        }
                    }
                }
            }
            Card {
                Text("Help and safety").scaledFont(17, .bold).foregroundStyle(Theme.text)
                Text("In Everyone, hold a message to report it or block its sender. To report abuse or a problem, write to \(Contact.email).")
                    .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Email us") { UIApplication.shared.open(Contact.mail) }.buttonStyle(GhostButton())
                    Button("Privacy policy") { UIApplication.shared.open(Contact.privacy) }.buttonStyle(GhostButton())
                }
            }
        }
        .onAppear { nameDraft = myName; groupDraft = groupName; blocked = Moderation.blocked }
    }

    private func clean(_ s: String, _ max: Int) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    private func open(_ s: MainView.Sheet) {
        Nav.shared.sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Nav.shared.sheet = s }
    }

    private func save() {
        let n = clean(nameDraft, 20), typed = clean(groupDraft, Invite.maxGroupName)
        let g = typed.isEmpty ? groupName : typed
        if g != groupName { groupName = g; SavedGroups.remember(.init(name: g, code: code)) }
        if n != myName { myName = n; engine.rejoin(name: n, code: code) }
        Nav.shared.toast("Saved")
        dismiss()
    }
}
