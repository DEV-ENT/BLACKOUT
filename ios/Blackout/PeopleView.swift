import SwiftUI
import BlackoutCore

// MARK: - Model

extension CheckIn {
    var label: String { self == .safe ? "Safe" : "Needs help" }
    var color: Color { self == .safe ? Theme.safe : Theme.help }
}

extension Engine {
    /// Sends a check-in to the group, with a haptic.
    func checkIn(_ c: CheckIn) {
        send(c.rawValue)
        UINotificationFeedbackGenerator().notificationOccurred(c == .safe ? .success : .warning)
    }

    /// Your own most recent check-in in this group.
    var myLastCheckIn: Message? {
        messages.last { !$0.isPublic && $0.sender == deviceId && CheckIn.of($0.text) != nil }
    }
}

extension View {
    /// Asks before telling the group you need help.
    func helpConfirmation(_ shown: Binding<Bool>, groupName: String, send: @escaping () -> Void) -> some View {
        confirmationDialog("Tell \(groupName) you need help?", isPresented: shown, titleVisibility: .visible) {
            Button("Send “I need help”", role: .destructive, action: send)
        } message: {
            Text("Then write in Chat what you need and where you are.")
        }
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

/// Groups this phone has been in, so random codes are never lost when switching. Stored only on this phone.
enum SavedGroups {
    struct Entry: Codable, Identifiable, Hashable { var name: String; var code: String; var id: String { code } }
    private static let key = "savedGroups"

    static func all() -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    static func remember(_ e: Entry) {
        let list = [e] + all().filter { $0.code != e.code }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(list.prefix(10))), forKey: key)
    }

    /// Makes [code] this phone's group: keeps the old one in the list, saves the new one, and re-reads the messages.
    static func switchTo(groupName: String, code: String, engine: Engine) {
        let d = UserDefaults.standard
        if let old = d.string(forKey: "code"), !old.isEmpty, old != code {
            remember(Entry(name: d.string(forKey: "groupName") ?? "My group", code: old))
        }
        remember(Entry(name: groupName, code: code))
        d.set(code, forKey: "code"); d.set(groupName, forKey: "groupName")
        engine.rejoin(name: engine.name, code: code)
    }
}

// MARK: - People tab

struct PeopleView: View {
    @ObservedObject var engine: Engine
    let open: (MainView.Sheet) -> Void
    @AppStorage("groupName") private var groupName = "My group"
    @State private var confirmHelp = false

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
                        Button { open(.group) } label: { RoundIcon(symbol: "gearshape.fill") }.accessibilityLabel("Group settings")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            BigCheckIn(checkIn: .safe) { engine.checkIn(.safe) }
                            BigCheckIn(checkIn: .help) { confirmHelp = true }
                        }
                        LastCheckIn(engine: engine, now: t.date).padding(.horizontal, 4)
                    }
                    if engine.phones == 0 { ConnectionHelp(engine: engine) }
                    if people.isEmpty {
                        NoPeopleCard(groupName: groupName) { open(.invite) }
                    } else {
                        PeopleList(people: people, engine: engine, now: t.date)
                        Button { open(.invite) } label: { Label("Invite friends", systemImage: "qrcode") }
                            .buttonStyle(SecondaryButton())
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
        }
        .helpConfirmation($confirmHelp, groupName: groupName) { engine.checkIn(.help) }
    }
}

/// Big green "I'm safe" or red "I need help" tile, in the logo's shape.
struct BigCheckIn: View {
    let checkIn: CheckIn
    let action: () -> Void

    var body: some View {
        let safe = checkIn == .safe
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: safe ? "checkmark.shield.fill" : "sos").font(.system(size: 30, weight: .bold))
                Text(safe ? "I'm safe" : "I need help").font(.system(size: 21, weight: .heavy))
            }
            .foregroundStyle(safe ? Color.black : .white)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .bottomLeading).padding(18)
            .background(VaultShape(cut: 28, radius: 32, small: 6).fill(checkIn.color))
            .contentShape(VaultShape(cut: 28, radius: 32, small: 6))
        }
        .buttonStyle(PressScale())
        .accessibilityHint(safe ? "Tells your group you're safe" : "Asks your group for help")
    }
}

/// "Your last check-in: safe, 12 min ago."
struct LastCheckIn: View {
    @ObservedObject var engine: Engine
    let now: Date

    var body: some View {
        if let m = engine.myLastCheckIn, let c = CheckIn.of(m.text) {
            Text("Your last check-in: \(c.label.lowercased()), \(ago(m.ts, now)).").font(.system(size: 14)).foregroundStyle(Theme.dim)
        } else {
            Text("One tap tells your group how you are.").font(.system(size: 14)).foregroundStyle(Theme.dim)
        }
    }
}

/// Shown while nobody from the group has written yet.
struct NoPeopleCard: View {
    let groupName: String
    let invite: () -> Void

    var body: some View {
        Card {
            Text("No one from \(groupName) yet").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            Text("Invite friends with a QR code, then keep DarkProof open near each other. People show up here once they write.")
                .font(.system(size: 15)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            Button(action: invite) { Label("Invite friends", systemImage: "qrcode") }.buttonStyle(PrimaryButton())
        }
    }
}

/// People in one card, divided by hairlines.
struct PeopleList: View {
    let people: [Person]
    @ObservedObject var engine: Engine
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            ForEach(people) { p in
                PersonRow(person: p, inRange: engine.linkedNodes.contains(p.id), now: now)
                if p.id != people.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 76) }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct PersonRow: View {
    let person: Person
    let inRange: Bool
    let now: Date

    var body: some View {
        let status: (String, Color) = person.checkIn.map { ("\($0.label) · \(ago(person.checkInTs, now))", $0.color) }
            ?? ("Last heard \(ago(person.lastTs, now))", Theme.dim)
        HStack(spacing: 14) {
            Text(String(person.name.prefix(1)).uppercased()).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: 46, height: 46).background(Circle().fill(Theme.tile))
                .overlay(Circle().stroke(person.checkIn?.color ?? .clear, lineWidth: 2.5).padding(-3))
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(status.0).font(.system(size: 14, weight: .medium)).foregroundStyle(status.1)
            }
            Spacer(minLength: 8)
            if inRange { Chip("Nearby") }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Connection help

/// Shown while no phone is in range: what to check, with live Bluetooth state.
struct ConnectionHelp: View {
    @ObservedObject var engine: Engine

    private var bluetoothProblem: String? {
        let s = engine.status["2-ble"] ?? ""
        if s.contains("Bluetooth is off") { return "Bluetooth is off. Turn it on in Control Center." }
        if s.contains("not allowed") { return "DarkProof may not use Bluetooth. Allow it in Settings." }
        if s.contains("not available") { return "This device has no Bluetooth." }
        return nil
    }

    var body: some View {
        Card {
            Text("No one in range yet").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            tip(bluetoothProblem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                bluetoothProblem == nil ? Theme.safe : Theme.help,
                bluetoothProblem ?? "Bluetooth is on.")
            tip("iphone.radiowaves.left.and.right", Theme.text,
                "Open DarkProof on both phones and stay within about 10–50 m. Walls cut the range: try outside or by a window.")
            tip("wifi", Theme.text, "If asked, allow Local Network: iPhones also connect over Wi-Fi, with no internet.")
            tip("point.3.connected.trianglepath.dotted", Theme.text,
                "Farther away? Messages hop through any phone with DarkProof in between. For kilometers, pair a LoRa radio.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(GhostButton())
        }
    }

    private func tip(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            Text(text).font(.system(size: 15)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Invite

struct InviteSheet: View {
    let groupName: String
    let code: String
    @State private var showCode = false
    private var url: URL { Invite.url(name: groupName, code: code) }

    var body: some View {
        SheetPage(title: "Invite") {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Invite to \(groupName)").font(.system(size: 28, weight: .heavy)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    Text("Your friend points their iPhone Camera at this code, then taps the DarkProof link.")
                        .font(.system(size: 15)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                }
                if let qr = Invite.qr(url) {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                        .padding(20)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Invite QR code")
                }
                ShareLink(item: url, subject: Text("Join \(groupName) on DarkProof"),
                          message: Text("Join my group \(groupName) on DarkProof. Group code: \(code)")) {
                    Label("Send invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButton())
                Text("AirDrop works without internet.").font(.footnote).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity)
            Card {
                Text("Or tell them the code").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                if showCode {
                    Text(code).font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                    Button("Copy code") { UIPasteboard.general.string = code }.buttonStyle(GhostButton())
                } else {
                    Button("Show code") { showCode = true }.buttonStyle(GhostButton())
                }
                Label("Anyone with this QR or code can read the group. Share it only with people you trust.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
        }
    }
}

// MARK: - Group settings

struct GroupSheet: View {
    @ObservedObject var engine: Engine
    let created: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("groupName") private var groupName = "My group"
    @AppStorage("code") private var code = ""
    @AppStorage("name") private var myName = ""
    @State private var nameDraft = ""
    @State private var groupDraft = ""
    @State private var joinCode = ""
    @State private var saved: [SavedGroups.Entry] = []

    var body: some View {
        SheetPage(title: "Settings") {
            Card {
                InputField(label: "Your name", hint: "Shown next to your messages.") {
                    TextField("", text: $nameDraft)
                }
                InputField(label: "Group name", hint: "Only on this phone. Each person can name it as they like.") {
                    TextField("", text: $groupDraft)
                }
                Button("Save") { save() }
                    .buttonStyle(PrimaryButton())
                    .disabled(clean(nameDraft, 20).isEmpty || clean(groupDraft, Invite.maxGroupName).isEmpty)
            }
            Card {
                Text("Your other groups").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                let others = saved.filter { $0.code != code }
                if others.isEmpty {
                    Text("Groups you switch away from are kept here, so you can come back.")
                        .font(.system(size: 15)).foregroundStyle(Theme.dim)
                }
                ForEach(others) { g in
                    HStack {
                        Text(g.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Switch") { switchTo(g.name, g.code) }.buttonStyle(GhostButton())
                    }
                }
            }
            Card {
                Text("Join or start another group").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                InputField(label: "Group code", hint: "Easier: point the iPhone Camera at a friend's invite QR.") {
                    TextField("", text: $joinCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                HStack(spacing: 10) {
                    Button("Join with code") { switchTo("Group", clean(joinCode, 200)) }
                        .buttonStyle(GhostButton()).disabled(clean(joinCode, 200).count < 8)
                    Button("Create a new group") {
                        switchTo("\(myName)'s group".prefix(Invite.maxGroupName).description, Invite.newCode())
                        created()
                    }
                    .buttonStyle(GhostButton())
                }
                Text("Switching shows the other group's messages. This group's messages stay on the phone.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
        }
        .onAppear { nameDraft = myName; groupDraft = groupName; saved = SavedGroups.all() }
    }

    private func clean(_ s: String, _ max: Int) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    private func save() {
        let n = clean(nameDraft, 20), g = clean(groupDraft, Invite.maxGroupName)
        if g != groupName { groupName = g; SavedGroups.remember(.init(name: g, code: code)) }
        if n != myName { myName = n; engine.rejoin(name: n, code: code) }
        dismiss()
    }

    private func switchTo(_ name: String, _ newCode: String) {
        SavedGroups.switchTo(groupName: name, code: newCode, engine: engine)
        dismiss()
    }
}
