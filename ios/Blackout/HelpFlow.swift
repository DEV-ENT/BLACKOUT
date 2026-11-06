import SwiftUI
import BlackoutCore

extension Engine {
    /// What to tell the user once a message is queued: "Sent" only when something can carry it right now.
    func queuedToast(_ what: String) -> String {
        let s = reach == .none ? "\(what) waits for a phone in range" : "Sent \(what)"
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// Need toggles and a head count (spec/FORMAT.md, "Needs and head count"), shared by "I need help", practice and
/// reports about someone else.
struct NeedsPicker: View {
    @Binding var needs: Set<Need>
    @Binding var people: Int
    var peopleTitle = "How many people need help?"
    var one = "Just me"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("What is needed? (optional)")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Need.allCases, id: \.self) { n in
                    let on = needs.contains(n)
                    Button { if on { needs.remove(n) } else { needs.insert(n) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").scaledFont(16, .semibold)
                            Text(n.label).scaledFont(15, .semibold).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .padding(.horizontal, 14).frame(minHeight: 48)
                        .background(on ? Color.white : Theme.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Kicker(peopleTitle)
            HStack(spacing: 12) {
                Text(people == 1 ? one : "\(people) people").scaledFont(17, .semibold).foregroundStyle(Theme.text)
                Spacer()
                Stepper("", value: $people, in: 1...99).labelsHidden()
                    .accessibilityLabel("Number of people").accessibilityValue("\(people)")
            }
            .padding(.horizontal, 16).frame(minHeight: 54)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// "I need help": the confirmation, with optional quick questions. One tap on the red button sends it.
struct HelpSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("groupName") private var groupName = "My group"
    @State private var needs: Set<Need> = []
    @State private var people = 1

    var body: some View {
        SheetPage(title: "I need help", close: "Cancel") {
            Text("Tell \(groupName) you need help?").scaledFont(26, .heavy).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Button { send() } label: { Label("Send “I need help”", systemImage: "sos") }
                .buttonStyle(DangerButton())
            Text("Add details below if you can. Your battery level goes with it, and your position if you share it (Settings).")
                .scaledFont(14).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            NeedsPicker(needs: $needs, people: $people)
            Button { send() } label: { Label("Send with these details", systemImage: "sos") }
                .buttonStyle(DangerButton())
            Text("Then write in Chat where you are and what happened. If you can reach emergency services, call them too.")
                .scaledFont(14).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func send() {
        let e = engine
        e.checkIn(.help, needs: needs, people: people > 1 ? people : nil) { Nav.shared.toast(e.queuedToast("“I need help”")) }
        dismiss()
    }
}

/// The red full-width button for "I need help".
struct DangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(17, .bold).foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.help, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// "Practice · nothing is sent"
struct PracticeLabel: View {
    var body: some View {
        Label("Practice · nothing is sent", systemImage: "graduationcap.fill")
            .scaledFont(14, .bold).foregroundStyle(Color.black)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.yellow, in: Capsule())
    }
}

/// A walk through "I need help" that sends nothing, so asking for help is familiar before it is needed.
struct PracticeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("name") private var myName = ""
    @AppStorage("groupName") private var groupName = "My group"
    @AppStorage("didPractice") private var didPractice = false
    @State private var step = 0
    @State private var needs: Set<Need> = []
    @State private var people = 1

    var body: some View {
        SheetPage(title: "Practice") {
            PracticeLabel()
            switch step {
            case 0:
                Text("Practice asking for help").scaledFont(26, .heavy).foregroundStyle(Theme.text)
                Text("In an emergency you tap the red button on Home or People. Try it now: nothing is sent to \(groupName).")
                    .scaledFont(16).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                BigCheckIn(checkIn: .help) { withAnimation { step = 1 } }
            case 1:
                Text("Tell \(groupName) you need help?").scaledFont(26, .heavy).foregroundStyle(Theme.text)
                Text("This screen asks first, so a tap by mistake sends nothing. Pick what you would need.")
                    .scaledFont(16).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                NeedsPicker(needs: $needs, people: $people)
                Button { withAnimation { step = 2 } } label: { Label("Send “I need help” (practice)", systemImage: "sos") }
                    .buttonStyle(DangerButton())
            default:
                Text("That's it").scaledFont(26, .heavy).foregroundStyle(Theme.text)
                Text("Your group would see this, with an alert:")
                    .scaledFont(16).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                let text = CheckIn.help.text(battery: Engine.batteryPercent, needs: needs, people: people > 1 ? people : nil)
                CheckInRow(checkIn: .help, name: myName.isEmpty ? "You" : myName, time: ChatTime.stamp(Int64(Date().timeIntervalSince1970 * 1000)),
                           battery: CheckIn.battery(in: text), needs: needs, people: people > 1 ? people : nil)
                Card {
                    tip("bubble.left.fill", "Then write in Chat where you are and what happened.")
                    tip("location.fill", "Turn on “Share my location in check-ins” in Settings so they can find you with a compass.")
                    tip("antenna.radiowaves.left.and.right", "It goes out over any phone, radio or internet link in reach, and waits until one is.")
                }
                Button("Done") { didPractice = true; dismiss() }.buttonStyle(PrimaryButton())
            }
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.text).frame(width: 22)
            Text(text).scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Are you safe?" to the whole group or one person (spec/FORMAT.md, "Are you safe?").
struct AskSafeSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("groupName") private var groupName = "My group"

    var body: some View {
        let people = Person.all(in: engine.messages, me: engine.deviceId).filter { !$0.isReport }
        SheetPage(title: "Are you safe?", close: "Cancel") {
            Text("Ask your group to check in. They get an alert with one-tap answers: I'm safe, I need help.")
                .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            Button { ask(nil) } label: { Label("Ask everyone in \(groupName)", systemImage: "person.3.fill") }
                .buttonStyle(PrimaryButton())
            if !people.isEmpty {
                Kicker("Or ask one person")
                VStack(spacing: 0) {
                    ForEach(people) { p in
                        Button { ask(p.name) } label: {
                            HStack {
                                Text(p.name).scaledFont(17, .semibold).foregroundStyle(Theme.text)
                                Spacer()
                                Text(p.checkIn.map { "\($0.label), \(ago(p.checkInTs, Date()))" } ?? "Not checked in")
                                    .scaledFont(14).foregroundStyle(p.checkIn?.color ?? Theme.dim)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ask \(p.name)")
                        if p.id != people.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 20) }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private func ask(_ name: String?) {
        engine.send(AreYouSafe(to: name).text)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Nav.shared.toast(engine.queuedToast(name.map { "the question to \($0)" } ?? "the question"))
        dismiss()
    }
}

/// Check in for someone without a phone or signal: "Grandma is safe (reported by Anna)" (spec, "Reports about others").
struct VouchSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var loc = LocationService.shared
    @State private var name = ""
    @State private var safe = true
    @State private var needs: Set<Need> = []
    @State private var people = 1
    @State private var withPosition = false
    @State private var sending = false

    private var cleanName: String {
        String(name.replacingOccurrences(of: "·", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Vouch.maxName))
    }

    var body: some View {
        SheetPage(title: "Check in for someone", close: "Cancel") {
            Text("For someone without a phone or signal, like a neighbour you found at the shelter. Your group sees it as reported by you.")
                .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            InputField(label: "Their name") {
                TextField("", text: $name, prompt: Text("Grandma Rosa").foregroundColor(Theme.faint)).submitLabel(.done)
            }
            PillSwitch(left: "Is safe", right: "Needs help", isRight: Binding(get: { !safe }, set: { safe = !$0 }))
            if safe {
                Kicker("How many people? (optional)")
                Stepper(people == 1 ? "Just them" : "\(people) people", value: $people, in: 1...99)
                    .scaledFont(17, .semibold).foregroundStyle(Theme.text)
                    .padding(.horizontal, 16).frame(minHeight: 54)
                    .background(Theme.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                NeedsPicker(needs: $needs, people: $people, one: "Just them")
            }
            Card {
                Toggle(isOn: $withPosition) {
                    Text("Add my position: they are with me").scaledFont(17, .bold).foregroundStyle(Theme.text)
                }
                .tint(Theme.safe)
                if withPosition && loc.denied {
                    Text("Location is off for DarkProof: it goes without a position.").font(.footnote).foregroundStyle(Theme.help)
                }
            }
            Button(sending ? "Getting your position…" : "Send to the group") { send() }
                .buttonStyle(PrimaryButton())
                .disabled(cleanName.isEmpty || sending)
        }
        .onChange(of: withPosition) { on in if on { loc.requestPermission() } }
    }

    private func send() {
        let v = { (spot: Spot?) in
            Vouch(subject: cleanName, status: safe ? .safe : .help, needs: safe ? [] : needs, people: people > 1 ? people : nil, spot: spot)
        }
        let finish = { (spot: Spot?) in
            engine.send(v(spot).text)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Nav.shared.toast(engine.queuedToast("the check-in for \(cleanName)"))
            sending = false
            dismiss()
        }
        guard withPosition else { return finish(nil) }
        sending = true
        loc.fix(finish)
    }
}
