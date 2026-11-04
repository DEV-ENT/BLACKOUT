import SwiftUI
import BlackoutCore

// MARK: - Model

extension CheckIn {
    var label: String { self == .safe ? "Safe" : "Needs help" }
    var color: Color { self == .safe ? Theme.live : Theme.alert }
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
    @Binding var showInvite: Bool
    @AppStorage("groupName") private var groupName = "My group"
    @AppStorage("code") private var code = ""
    @State private var settings = false
    @State private var confirmHelp = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { t in
            let people = Person.all(in: engine.messages, me: engine.deviceId)
            let inRange = people.filter { engine.linkedNodes.contains($0.id) }.count
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        HStack {
                            Kicker("Your group", color: Theme.amber)
                            Spacer()
                            Button { settings = true } label: {
                                Image(systemName: "gearshape.fill").font(.body).foregroundStyle(Theme.dim)
                            }
                            .accessibilityLabel("Group and name settings")
                        }
                        Text(groupName).font(Theme.mono(26, .heavy)).foregroundStyle(Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(people.isEmpty ? "No one heard from yet" : "\(people.count) heard from · \(inRange) in range now")
                            .font(.subheadline).foregroundStyle(Theme.dim)
                        Button { showInvite = true } label: { Label("Invite friends", systemImage: "qrcode") }
                            .buttonStyle(PrimaryButton())
                    }
                    checkInCard(t.date)
                    if engine.phones == 0 { ConnectionHelp(engine: engine) }
                    Kicker(people.isEmpty ? "People" : "People · \(people.count)").padding(.top, 6).padding(.horizontal, 4)
                    if people.isEmpty {
                        Text("Nobody from \(groupName) yet. Invite friends, then keep Blackout open near each other.")
                            .font(.subheadline).foregroundStyle(Theme.dim).padding(.horizontal, 4)
                    }
                    ForEach(people) { PersonRow(person: $0, inRange: engine.linkedNodes.contains($0.id), now: t.date) }
                }
                .padding(12)
            }
        }
        .confirmationDialog("Tell \(groupName) you need help?", isPresented: $confirmHelp, titleVisibility: .visible) {
            Button("Send “I need help”", role: .destructive) { send(.help) }
        } message: {
            Text("Then write in Chat what you need and where you are.")
        }
        .sheet(isPresented: $showInvite) { InviteSheet(groupName: groupName, code: code) }
        .sheet(isPresented: $settings) {
            GroupSheet(engine: engine) { // a new group was created: invite people to it
                settings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showInvite = true }
            }
        }
    }

    private func checkInCard(_ now: Date) -> some View {
        let mine = engine.messages.last { !$0.isPublic && $0.sender == engine.deviceId && CheckIn.of($0.text) != nil }
        return Card {
            Kicker("Check in")
            Text("One tap tells your group how you are.").font(.subheadline).foregroundStyle(Theme.text)
            HStack(spacing: 10) {
                Button { send(.safe) } label: { Label("I'm safe", systemImage: "checkmark.shield.fill") }
                    .buttonStyle(StatusButton(color: Theme.live))
                Button { confirmHelp = true } label: { Label("Need help", systemImage: "sos") }
                    .buttonStyle(StatusButton(color: Theme.alert))
            }
            if let mine, let c = CheckIn.of(mine.text) {
                Text("You said: \(c.label.lowercased()) · \(ago(mine.ts, now))").font(Theme.mono(11)).foregroundStyle(c.color)
            }
        }
    }

    private func send(_ c: CheckIn) {
        engine.send(c.rawValue)
        UINotificationFeedbackGenerator().notificationOccurred(c == .safe ? .success : .warning)
    }
}

struct PersonRow: View {
    let person: Person
    let inRange: Bool
    let now: Date

    var body: some View {
        let color = person.checkIn?.color ?? Theme.dim
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.14))
                Circle().stroke(color.opacity(0.6), lineWidth: 1)
                Text(String(person.name.prefix(1)).uppercased()).font(Theme.mono(17, .bold)).foregroundStyle(color)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    if inRange {
                        Circle().fill(Theme.live).frame(width: 7, height: 7)
                        Text("In range now").foregroundStyle(Theme.live)
                    } else {
                        Text("Last heard \(ago(person.lastTs, now))").foregroundStyle(Theme.dim)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            if let c = person.checkIn {
                VStack(alignment: .trailing, spacing: 3) {
                    Chip(c.label, c.color)
                    Text(ago(person.checkInTs, now)).font(Theme.mono(10)).foregroundStyle(Theme.dim)
                }
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(person.checkIn == .help ? Theme.alert.opacity(0.7) : Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Big filled button for a check-in.
struct StatusButton: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(14, .bold)).textCase(.uppercase)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Connection help

/// Shown while no phone is in range: what to check, with live Bluetooth state.
struct ConnectionHelp: View {
    @ObservedObject var engine: Engine

    private var bluetoothProblem: String? {
        let s = engine.status["2-ble"] ?? ""
        if s.contains("Bluetooth is off") { return "Bluetooth is off. Turn it on in Control Center." }
        if s.contains("not allowed") { return "Blackout may not use Bluetooth. Allow it in Settings." }
        if s.contains("not available") { return "This device has no Bluetooth." }
        return nil
    }

    var body: some View {
        Card {
            HStack(spacing: 0) { Kicker("No one in range yet", color: Theme.amber); Cursor().font(Theme.mono(11, .semibold)) }
            tip(bluetoothProblem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                bluetoothProblem == nil ? Theme.live : Theme.alert,
                bluetoothProblem ?? "Bluetooth is on.")
            tip("iphone.radiowaves.left.and.right", Theme.amber,
                "Open Blackout on both phones and stay within about 10–50 m. Walls cut the range: try outside or by a window.")
            tip("wifi", Theme.amber, "If asked, allow Local Network: iPhones also connect over Wi-Fi, with no internet.")
            tip("point.3.connected.trianglepath.dotted", Theme.amber,
                "Farther away? Messages hop through any phone with Blackout in between. For kilometers, pair a LoRa radio in the Radio tab.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(GhostButton())
        }
    }

    private func tip(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            Text(text).font(.subheadline).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Invite

struct InviteSheet: View {
    let groupName: String
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var showCode = false
    private var url: URL { Invite.url(name: groupName, code: code) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Kicker("Invite to", color: Theme.amber)
                        Text(groupName).font(Theme.mono(26, .heavy)).foregroundStyle(Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if let qr = Invite.qr(url) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .padding(18)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .frame(maxWidth: 290)
                            .accessibilityLabel("Invite QR code")
                    }
                    Text("Your friend points their iPhone Camera at this code, then taps the Blackout link.")
                        .font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                    ShareLink(item: url, subject: Text("Join \(groupName) on Blackout"),
                              message: Text("Join my group \(groupName) on Blackout. Group code: \(code)")) {
                        Label("Send invite", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButton())
                    Text("AirDrop works without internet.").font(.footnote).foregroundStyle(Theme.dim)
                    Card {
                        Kicker("Or tell them the code")
                        if showCode {
                            Text(code).font(Theme.mono(22, .bold)).foregroundStyle(Theme.text).textSelection(.enabled)
                            Button("Copy code") { UIPasteboard.general.string = code }.buttonStyle(GhostButton())
                        } else {
                            Button("Show code") { showCode = true }.buttonStyle(GhostButton())
                        }
                        Text("Anyone with this QR or code can read the group. Share it only with people you trust.")
                            .font(.footnote).foregroundStyle(Theme.alert)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Invite").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.font(Theme.mono(15, .bold)) }
        }
        .preferredColorScheme(.dark)
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
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
                        Kicker("Your other groups")
                        let others = saved.filter { $0.code != code }
                        if others.isEmpty {
                            Text("Groups you switch away from are kept here, so you can come back.")
                                .font(.subheadline).foregroundStyle(Theme.dim)
                        }
                        ForEach(others) { g in
                            HStack {
                                Text(g.name).font(Theme.mono(15, .semibold)).foregroundStyle(Theme.text)
                                Spacer()
                                Button("Switch") { switchTo(g.name, g.code) }.buttonStyle(GhostButton())
                            }
                        }
                    }
                    Card {
                        Kicker("Join or start another group")
                        InputField(label: "Group code", hint: "Easier: point the iPhone Camera at a friend's invite QR.") {
                            TextField("", text: $joinCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        }
                        Button("Join with this code") { switchTo("Group", clean(joinCode, 200)) }
                            .buttonStyle(GhostButton()).disabled(clean(joinCode, 200).count < 8)
                        Button("Create a new group") {
                            switchTo("\(myName)'s group".prefix(Invite.maxGroupName).description, Invite.newCode())
                            created()
                        }
                        .buttonStyle(GhostButton())
                        Text("Switching shows the other group's messages. This group's messages stay on the phone.")
                            .font(.footnote).foregroundStyle(Theme.dim)
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Group").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.font(Theme.mono(15, .bold)) }
            .onAppear { nameDraft = myName; groupDraft = groupName; saved = SavedGroups.all() }
        }
        .preferredColorScheme(.dark)
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
