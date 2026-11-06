import SwiftUI
import PhotosUI
import BlackoutCore

struct RootView: View {
    @AppStorage("name") private var name = ""
    @AppStorage("code") private var code = ""
    @AppStorage("groupName") private var groupName = "My group"
    @ObservedObject private var mesh = Mesh.shared
    private var engine: Engine? { mesh.engine }
    @State private var invite: PendingInvite?   // from an invite link, before setup
    @State private var linkInvite: PendingInvite? // from an invite link, once in a group: asks before switching

    var body: some View {
        Group {
            if let engine {
                MainView(engine: engine)
                    .sheet(item: $linkInvite) { i in JoinGroupSheet(engine: engine, prefill: (i.name, i.code)) }
            } else if code.isEmpty {
                SetupView(invite: invite) { n, g, c, created in
                    SavedGroups.remember(.init(name: g, code: c))
                    name = n; groupName = g; code = c
                    Nav.shared.inviteAfterSetup = created
                    mesh.start(name: n, code: c)
                    invite = nil
                }
            } else {
                Theme.bg.ignoresSafeArea().onAppear { mesh.startIfSetUp() }
            }
        }
        .tint(Theme.text)
        .onOpenURL { url in
            guard let i = Invite.parse(url) else { return }
            if code.isEmpty { invite = PendingInvite(name: i.name, code: i.code); return }
            if i.code == code { Nav.shared.toast("You're already in \(groupName)"); return }
            linkInvite = PendingInvite(name: i.name, code: i.code) // already in a group: ask first
        }
    }
}

struct PendingInvite: Equatable, Identifiable { let name: String; let code: String; var id: String { code } }

// MARK: - Setup

struct SetupView: View {
    var invite: PendingInvite?
    /// name, group name, group code, and whether the group was just created
    let done: (String, String, String, Bool) -> Void
    enum Mode { case welcome, create, join, ready }
    @State private var mode = Mode.welcome
    @State private var before = Mode.welcome // where "back" goes from the last step
    @State private var name = ""
    @State private var groupName = ""
    @State private var code = ""
    @State private var result: (String, String, String, Bool)?
    @FocusState private var focus: Field?
    @FocusState private var codeFocus: Bool
    enum Field { case name, group }

    private func clean(_ s: String, _ max: Int) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max)) }
    private var cleanName: String { clean(name, 20) }
    private var cleanCode: String { Invite.normalizeCode(code) }

    var body: some View {
        Group {
            if mode == .ready {
                ready
            } else if let invite {
                form(title: "You're invited", subtitle: "Join \(invite.name) to message each other without internet.", back: false) {
                    nameField
                    Button("Join \(invite.name)") { next(cleanName, invite.name, invite.code, false) }
                        .buttonStyle(PrimaryButton()).disabled(cleanName.isEmpty)
                }
            } else {
                switch mode {
                case .welcome, .ready: welcome
                case .create: create
                case .join: join
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    /// Before the last step: what DarkProof will ask for, so the questions that follow make sense.
    private func next(_ n: String, _ g: String, _ c: String, _ created: Bool) {
        focus = nil; codeFocus = false
        result = (n, g, c, created)
        before = mode
        withAnimation(.easeOut(duration: 0.2)) { mode = .ready }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Logo(size: 150).frame(maxWidth: .infinity)
            Spacer()
            Text("Stay connected when everything goes dark.")
                .scaledFont(40, .heavy).tracking(-1).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Messages travel phone to phone over Bluetooth and Wi-Fi, and over the internet when there is some. No account.")
                .scaledFont(17).foregroundStyle(Theme.dim).padding(.top, 14)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                Button { mode = .create } label: { Label("Create a group", systemImage: "plus") }.buttonStyle(PrimaryButton())
                Button { mode = .join } label: { Label("Join a group", systemImage: "qrcode.viewfinder") }.buttonStyle(SecondaryButton())
            }
            .padding(.top, 36)
            Text("Free and private. No servers of ours.").font(.footnote).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity).padding(.top, 14)
        }
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var create: some View {
        form(title: "Create a group", subtitle: "For your family, friends or building. DarkProof makes a secret code for it, then you invite people with a QR code.") {
            nameField
            InputField(label: "Group name (optional)", hint: "You can change it later.", active: focus == .group, tap: { focus = .group }) {
                TextField("", text: $groupName, prompt: Text(SavedGroups.defaultName(for: cleanName)).foregroundColor(Theme.faint))
                    .focused($focus, equals: .group).submitLabel(.done)
            }
            Button("Create group") {
                let g = clean(groupName, Invite.maxGroupName)
                next(cleanName, g.isEmpty ? SavedGroups.defaultName(for: cleanName) : g, Invite.newCode(), true)
            }
            .buttonStyle(PrimaryButton()).disabled(cleanName.isEmpty)
        }
    }

    private var join: some View {
        form(title: "Join a group", subtitle: "Scan your friend's invite QR code, or point the iPhone Camera at it. Or type their code.") {
            nameField
            CodeEntry(code: $code, groupName: $groupName, focusCode: $codeFocus)
            Button("Join") {
                let g = clean(groupName, Invite.maxGroupName)
                next(cleanName, g.isEmpty ? "Group" : g, cleanCode, false)
            }
            .buttonStyle(PrimaryButton()).disabled(cleanName.isEmpty || cleanCode.count < Invite.minCodeLength)
            if cleanName.isEmpty && !code.isEmpty {
                Text("Enter your name.").font(.footnote).foregroundStyle(Theme.dim)
            }
        }
    }

    private var ready: some View {
        form(title: "Almost done", subtitle: "DarkProof will ask for Bluetooth, Local Network and notifications so phones can find each other and you get alerts.",
             backTo: before) {
            Card {
                permission("dot.radiowaves.left.and.right", "Bluetooth", "Finds phones with DarkProof nearby, with no internet.")
                permission("wifi", "Local Network", "Connects over Wi-Fi, even a router or hotspot with no internet.")
                permission("bell.fill", "Notifications", "Tells you when your group writes or someone needs help.")
            }
            Text("Please tap Allow each time. You can change this later in Settings.").scaledFont(15).foregroundStyle(Theme.dim)
            Button("Continue") { if let r = result { done(r.0, r.1, r.2, r.3) } }.buttonStyle(PrimaryButton())
        }
    }

    private func permission(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).scaledFont(18, .semibold).foregroundStyle(Theme.text)
                .frame(width: 40, height: 40).background(Circle().fill(Theme.tile))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(17, .semibold).foregroundStyle(Theme.text)
                Text(text).scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var nameField: some View {
        InputField(label: "Your name", hint: "Shown next to your messages.", active: focus == .name, tap: { focus = .name }) {
            TextField("", text: $name, prompt: Text("Anna").foregroundColor(Theme.faint))
                .focused($focus, equals: .name).submitLabel(.done).textContentType(.givenName)
        }
    }

    private func form<C: View>(title: String, subtitle: String, back: Bool = true, backTo: Mode = .welcome,
                               @ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if back {
                    Button { focus = nil; codeFocus = false; withAnimation(.easeOut(duration: 0.2)) { mode = backTo } } label: {
                        RoundIcon(symbol: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                } else {
                    Logo(size: 44)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).scaledFont(34, .heavy).tracking(-0.5).foregroundStyle(Theme.text)
                    Text(subtitle).scaledFont(17).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Labeled text field; [active] outlines it while it has focus. VoiceOver reads the label and hint with the field.
struct InputField<Field: View>: View {
    let label: String
    var hint = ""
    var active = false
    var tap: () -> Void = {} // focuses the field when the box around the text is tapped
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(label).accessibilityHidden(true)
            field()
                .scaledFont(17).foregroundStyle(Theme.text).tint(Theme.text)
                .padding(.horizontal, 18).frame(minHeight: 54)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(active ? Theme.text.opacity(0.6) : .clear, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture(perform: tap)
                .accessibilityLabel(label)
                .accessibilityHint(hint)
            if !hint.isEmpty { Text(hint).font(.footnote).foregroundStyle(Theme.dim).accessibilityHidden(true) }
        }
    }
}

// MARK: - Main

struct MainView: View {
    enum Sheet: String, Identifiable { case invite, settings, radio, groups, help, practice, askSafe, vouch, shortcut, models; var id: String { rawValue } }
    @ObservedObject var engine: Engine
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var unread = Unread.shared
    @ObservedObject private var notifier = Notifier.shared
    @AppStorage("groupName") private var groupName = "My group"
    @AppStorage("code") private var code = ""
    @AppStorage("askedNotifications") private var askedNotifications = false
    @State private var asking = false

    var body: some View {
        TabView(selection: $nav.tab) {
            HomeView(engine: engine)
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(Nav.Tab.home)
            ChatView(engine: engine)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }.tag(Nav.Tab.chat)
                .badge(unread.count(code, in: engine.allMessages, me: engine.deviceId))
            PlacesView(engine: engine).tabItem { Label("Places", systemImage: "mappin.and.ellipse") }.tag(Nav.Tab.places)
            PeopleView(engine: engine).tabItem { Label("People", systemImage: "person.2.fill") }.tag(Nav.Tab.people)
            AiView(engine: engine).tabItem { Label("Ask", systemImage: "sparkles") }.tag(Nav.Tab.ask)
        }
        .tint(Theme.text)
        .modifier(Overlays())
        .sheet(item: $nav.sheet) { s in
            switch s {
            case .invite: InviteSheet(groupName: groupName, code: code)
            case .settings: GroupSheet(engine: engine)
            case .radio: ConnectionsView(engine: engine)
            case .groups: GroupSwitcher(engine: engine)
            case .help: HelpSheet(engine: engine)
            case .practice: PracticeSheet()
            case .askSafe: AskSafeSheet(engine: engine)
            case .vouch: VouchSheet(engine: engine)
            case .shortcut: ShortcutSheet()
            case .models: ModelPicker(ai: LocalAi.shared)
            }
        }
        .onAppear { firstRun() }
        .onChange(of: engine.networkStarted) { _ in firstRun() }
    }

    /// Right after setup, iOS asks one thing at a time: Bluetooth (Engine), then Local Network once the Wi-Fi links
    /// start, then notifications here, once those questions are answered; the invite opens last.
    private func firstRun() {
        if askedNotifications {
            if nav.inviteAfterSetup { nav.inviteAfterSetup = false; nav.sheet = .invite }
            return
        }
        guard engine.networkStarted, !asking else { return }
        asking = true
        whenNoSystemQuestion(after: 2) {
            askedNotifications = true
            notifier.requestPermission {
                if nav.inviteAfterSetup { nav.inviteAfterSetup = false; nav.sheet = .invite }
            }
        }
    }

    /// Waits until no system question is on screen (the app is active again), at most a minute.
    private func whenNoSystemQuestion(after s: Double, tries: Int = 120, _ then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) {
            if UIApplication.shared.applicationState == .active || tries <= 0 { then() }
            else { whenNoSystemQuestion(after: 0.5, tries: tries - 1, then) }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var unread = Unread.shared
    @AppStorage("groupName") private var groupName = "My group"
    @AppStorage("code") private var code = ""
    @State private var details = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { t in
            let people = Person.all(in: engine.messages, me: engine.deviceId)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    SetupProblemCard(engine: engine)
                    hero
                    if engine.reach == .none && engine.setupProblem == nil { ConnectionHelp(engine: engine) }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            QuickAction(symbol: "checkmark.shield.fill", label: engine.checkInSending == .safe ? "Sending…" : "I'm safe", tint: Theme.safe) {
                                let e = engine
                                e.checkIn(.safe) { nav.toast(e.queuedToast("“I'm safe”")) }
                            }
                            .disabled(engine.checkInSending != nil)
                            QuickAction(symbol: "sos", label: engine.checkInSending == .help ? "Sending…" : "Need help", tint: Theme.help) { nav.sheet = .help }
                                .disabled(engine.checkInSending != nil)
                            QuickAction(symbol: "qrcode", label: "Invite", tint: Theme.text) { nav.sheet = .invite }
                            QuickAction(symbol: "antenna.radiowaves.left.and.right", label: "Connect", tint: Theme.text) { nav.sheet = .radio }
                        }
                        LastCheckIn(engine: engine, now: t.date).padding(.horizontal, 4)
                        if let h = battery.hoursLeft {
                            Label("Battery: \(BatteryMonitor.text(h)) at this pace", systemImage: h < 4 ? "battery.25percent" : "battery.75percent")
                                .scaledFont(14).foregroundStyle(h < 4 ? Theme.help : Theme.dim).padding(.horizontal, 4)
                        }
                    }
                    GetReadyCard(engine: engine, hasPeople: !people.isEmpty)
                    SectionTitle(title: "Your people", action: people.count > 3 ? "See all" : nil) { nav.tab = .people }
                    if people.isEmpty {
                        NoPeopleCard(groupName: groupName) { nav.sheet = .invite }
                    } else {
                        PeopleList(people: Array(people.prefix(3)), engine: engine, now: t.date)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
        }
    }

    /// Other saved groups with something new: a dot next to the group name.
    private var othersNeedLook: Bool {
        SavedGroups.all().contains { g in g.code != code && unread.count(g.code, in: engine.allMessages, me: engine.deviceId) > 0 }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Logo(size: 30)
            Button { nav.sheet = .groups } label: {
                HStack(spacing: 5) {
                    Text(groupName).scaledFont(22, .bold).lineLimit(1)
                    Image(systemName: "chevron.down").scaledFont(13, .bold).foregroundStyle(Theme.dim)
                    if othersNeedLook { Circle().fill(Theme.text).frame(width: 8, height: 8).accessibilityHidden(true) }
                }
                .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Group: \(groupName)" + (othersNeedLook ? ", other groups have new messages" : ""))
            .accessibilityHint("Switch, join or create a group")
            Spacer()
            Button { nav.sheet = .settings } label: { RoundIcon(symbol: "gearshape.fill") }.accessibilityLabel("Settings")
        }
    }

    private var linkSummary: String {
        var via: [String] = []
        if engine.bluetoothLinks > 0 { via.append("Bluetooth") }
        if engine.wifiLinks > 0 { via.append("Wi-Fi") }
        if engine.radioLinked || engine.meshcoreLinked { via.append("LoRa radio") }
        let how = via.isEmpty ? "" : "Over \(ListFormatter.localizedString(byJoining: via)). "
        return how + "Your messages hop from phone to phone." + (engine.relaysLinked > 0 ? " Also online." : "")
    }

    private var hero: some View {
        let r = engine.reach
        let on = r != .none
        let label: String = {
            switch r {
            case .phones: return "Connected"
            case .online(let n): return "Internet · \(n) \(n == 1 ? "relay" : "relays")"
            case .radio: return "LoRa radio linked"
            case .none: return "Looking for phones"
            }
        }()
        return Button { withAnimation(.easeOut(duration: 0.2)) { details.toggle() } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(on ? Theme.safe : Theme.dim).frame(width: 9, height: 9)
                    Text(label).scaledFont(15, .semibold).foregroundStyle(on ? Theme.safe : Theme.dim)
                    Spacer()
                    Image(systemName: "chevron.down").scaledFont(13, .bold).foregroundStyle(Theme.decor)
                        .rotationEffect(.degrees(details ? 180 : 0))
                }
                switch r {
                case .online:
                    Text("Online").scaledFont(64, .heavy).tracking(-2).foregroundStyle(Theme.text).padding(.vertical, 6)
                    Text("Online · your messages also travel over the internet. No phone in range yet: they hop phone to phone once one is.")
                        .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                case .radio:
                    Text("LoRa").scaledFont(64, .heavy).tracking(-2).foregroundStyle(Theme.text).padding(.vertical, 6)
                    Text("Short messages reach other radios kilometers away. No phone in range yet.")
                        .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                default:
                    HStack(alignment: .lastTextBaseline, spacing: 12) {
                        Text("\(engine.phones)").scaledFont(84, .heavy).tracking(-3).foregroundStyle(Theme.text)
                        Text(engine.phones == 1 ? "phone\nin range" : "phones\nin range")
                            .scaledFont(21, .bold).foregroundStyle(Theme.dim).padding(.bottom, 12)
                    }
                    Text(r == .none ? "Keep DarkProof open. Your messages wait and go out as soon as a phone is in range." : linkSummary)
                        .scaledFont(15).foregroundStyle(Theme.dim).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if details {
                    VStack(alignment: .leading, spacing: 4) { ForEach(engine.friendlyStatus, id: \.self) { Text($0) } }
                        .scaledFont(14).foregroundStyle(Theme.dim).padding(.top, 10)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(VaultShape().fill(Theme.card))
            .contentShape(VaultShape())
        }
        .buttonStyle(.plain)
        .accessibilityHint(details ? "Hides connection details" : "Shows connection details")
    }
}

/// One of the four square shortcuts on Home.
struct QuickAction: View {
    let symbol: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).scaledFont(20, .semibold).foregroundStyle(tint)
                    .frame(width: 44, height: 44).background(Circle().fill(tint.opacity(0.14)))
                Text(label).scaledFont(13, .semibold).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// Shrinks a custom-drawn button a little while pressed; dims it while disabled.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(!enabled ? 0.5 : configuration.isPressed ? 0.85 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

// MARK: - Chat

/// Message times in the user's own format ("14:05" or "2:05 PM"); older messages get a day.
enum ChatTime {
    static let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
    private static let day: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEdMMMM"); return f }()
    private static let dayYear: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEdMMMMy"); return f }()
    private static let shortDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("dMMM"); return f }()

    static func date(_ ts: Int64) -> Date { Date(timeIntervalSince1970: Double(ts) / 1000) }

    /// "14:05" today, "Yesterday, 14:05", "3 Nov, 14:05" before.
    static func stamp(_ ts: Int64, now: Date = Date()) -> String {
        let d = date(ts), cal = Calendar.current, t = time.string(from: d)
        if cal.isDate(d, inSameDayAs: now) { return t }
        if cal.isDateInYesterday(d) { return "Yesterday, \(t)" }
        return "\(shortDay.string(from: d)), \(t)"
    }

    /// Day separator: "Today", "Yesterday", "Monday 3 November".
    static func dayTitle(_ ts: Int64, now: Date = Date()) -> String {
        let d = date(ts), cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return cal.isDate(d, equalTo: now, toGranularity: .year) ? day.string(from: d) : dayYear.string(from: d)
    }

    static func sameDay(_ a: Int64, _ b: Int64) -> Bool { Calendar.current.isDate(date(a), inSameDayAs: date(b)) }
}

struct ChatView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var drafts = Drafts.shared
    @ObservedObject private var unread = Unread.shared
    @State private var tooLong = false
    @State private var readers: ReaderList?
    @State private var findingPlace: SharedPlace?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var pending: PendingPhoto?
    @State private var viewing: ViewedPhoto?
    @State private var blocking: Message?
    @State private var photoFailed = false
    @State private var atBottom = true
    @State private var newBelow = 0
    @ObservedObject private var loc = LocationService.shared
    @AppStorage("groupName") private var groupName = "My group"
    @AppStorage("code") private var code = ""
    @AppStorage("name") private var myName = ""
    @Environment(\.scenePhase) private var phase

    private var toPublic: Bool { nav.chatEveryone }
    private var channel: String { toPublic ? Unread.everyone : code }
    private var shown: [Message] { engine.messages.filter { $0.isPublic == toPublic } }

    @ViewBuilder private func moderationMenu(_ m: Message, mine: Bool) -> some View {
        if mine {
            if m.isPublic && Place.of(m.text) != nil {
                Button(role: .destructive) { Moderation.hide(m.id); engine.moderationChanged(); nav.toast("Removed from this phone") } label: {
                    Label("Remove from this phone", systemImage: "trash")
                }
            }
        } else {
            Button(role: .destructive) { blocking = m } label: { Label("Block \(m.name)", systemImage: "hand.raised") }
            if m.isPublic {
                Button(role: .destructive) {
                    Moderation.report(m.id); engine.moderationChanged()
                    nav.toast("Reported and hidden on this phone")
                } label: {
                    Label("Report this message", systemImage: "exclamationmark.bubble")
                }
            }
        }
    }

    /// Whether I checked in, in this group, after the question was asked.
    private func answered(after ts: Int64) -> Bool {
        engine.messages.contains { !$0.isPublic && $0.sender == engine.deviceId && $0.ts > ts && CheckIn.of($0.text) != nil }
    }

    private func markRead() {
        guard nav.tab == .chat, phase == .active, atBottom, let last = shown.last else { return }
        unread.markRead(channel, upTo: last.ts)
    }

    var body: some View {
        let list = shown
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenTitle(title: toPublic ? "Everyone" : groupName, subtitle: engine.reachLine)
                ChannelSwitch(toPublic: $nav.chatEveryone, groupName: groupName,
                              groupNew: unread.count(code, in: engine.allMessages, me: engine.deviceId),
                              everyoneNew: unread.count(Unread.everyone, in: engine.allMessages, me: engine.deviceId))
                Text(toPublic ? "Anyone with DarkProof can read these, nearby or online." : "Only people in \(groupName) can read these.")
                    .scaledFont(13).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)

            if list.isEmpty {
                EmptyState(symbol: toPublic ? "megaphone.fill" : "bubble.left.and.bubble.right.fill",
                           title: "No messages yet",
                           text: toPublic ? "Messages for everyone show up here, nearby or online, from any group."
                                          : "Write the first one. It reaches everyone in \(groupName) who is in range, or later when they are.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                                let prev = i > 0 ? list[i - 1] : nil
                                if prev == nil || !ChatTime.sameDay(prev!.ts, m.ts) {
                                    Text(ChatTime.dayTitle(m.ts)).scaledFont(13, .semibold).foregroundStyle(Theme.dim)
                                        .padding(.horizontal, 12).padding(.vertical, 5).background(Theme.tile, in: Capsule())
                                        .padding(.vertical, 8).accessibilityAddTraits(.isHeader)
                                }
                                row(m, prev: prev, first: i == 0)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                                .onAppear { atBottom = true; newBelow = 0; markRead() }
                                .onDisappear { atBottom = false }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .overlay(alignment: .bottomTrailing) {
                        if newBelow > 0 {
                            Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                                Label("\(newBelow) new", systemImage: "arrow.down").scaledFont(14, .bold).foregroundStyle(Color.black)
                                    .padding(.horizontal, 14).padding(.vertical, 9).background(Color.white, in: Capsule())
                            }
                            .padding(16)
                            .accessibilityLabel("\(newBelow) new messages. Go to the newest")
                        }
                    }
                    // A new message scrolls down only if you were at the bottom already, or wrote it.
                    .onChange(of: list.last?.id) { _ in
                        guard let last = shown.last else { return }
                        if atBottom || last.sender == engine.deviceId {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                            DispatchQueue.main.async { markRead() }
                        } else {
                            newBelow += 1
                        }
                    }
                    .onChange(of: toPublic) { _ in
                        newBelow = 0
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom); markRead() }
                    }
                    .onAppear { // open on the newest messages, once the list has been laid out
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom); markRead() }
                    }
                    .onChange(of: nav.tab) { t in if t == .chat { markRead() } }
                    .onChange(of: phase) { p in if p == .active { markRead() } }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if toPublic {
                    Label("To everyone: anyone with DarkProof can read it", systemImage: "megaphone.fill")
                        .scaledFont(13, .semibold).foregroundStyle(Theme.text).padding(.horizontal, 6)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    if !toPublic {
                        Menu {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                Button { takingPhoto = true } label: { Label("Take photo", systemImage: "camera") }
                            }
                            Button { choosingPhoto = true } label: { Label("Choose photo", systemImage: "photo.on.rectangle") }
                        } label: {
                            Image(systemName: "camera.fill").scaledFont(18, .semibold).foregroundStyle(Theme.text)
                                .frame(width: 50, height: 50).background(Circle().fill(Theme.tile))
                        }
                        .accessibilityLabel("Send a photo")
                    }
                    Composer(draft: drafts.binding(channel), placeholder: toPublic ? "Message everyone" : "Message \(groupName)",
                             isPublic: toPublic, send: send)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(item: $readers) { DeliveredSheet(readers: $0.readers) }
        .sheet(item: $findingPlace) { FindSheet(place: $0.place, by: $0.by, ts: $0.ts) }
        .sheet(item: $viewing) { PhotoViewer(jpeg: $0.jpeg, caption: $0.caption, from: $0.from) }
        .confirmationDialog("Block \(blocking?.name ?? "")?", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
                            titleVisibility: .visible, presenting: blocking) { m in
            Button("Block", role: .destructive) {
                Moderation.block(m.sender, name: m.name); engine.moderationChanged(); blocking = nil
                nav.toast("\(m.name) is blocked on this phone")
            }
        } message: { _ in
            Text("You won't see their messages, places or check-ins on this phone. You can unblock them in Settings.")
        }
        .sheet(item: $pending) { p in
            PhotoSendSheet(photo: p, groupName: groupName) { caption in
                engine.send(Photo.text(caption: caption), photo: p.jpeg)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run { photoItem = nil; prepare(data.flatMap { UIImage(data: $0) }) }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in takingPhoto = false; prepare(image) }.ignoresSafeArea()
        }
        .alert("This photo couldn't be made small enough to send.", isPresented: $photoFailed) { Button("OK", role: .cancel) {} }
        .alert("Too long for the LoRa radio", isPresented: $tooLong) { Button("OK", role: .cancel) {} } message: {
            Text("It travels only over Bluetooth, Wi-Fi and the internet. Shorter messages also go over the radio.")
        }
    }

    @ViewBuilder private func row(_ m: Message, prev: Message?, first: Bool) -> some View {
        let mine = m.sender == engine.deviceId
        let newRun = prev == nil || prev!.sender != m.sender || prev!.name != m.name || CheckIn.of(prev!.text) != nil
            || !ChatTime.sameDay(prev!.ts, m.ts)
        let time = ChatTime.time.string(from: ChatTime.date(m.ts))
        let delivery = engine.delivery(of: m)
        let showReaders: () -> Void = {
            if case .delivered(let r) = delivery { readers = ReaderList(id: m.id, readers: r) }
        }
        Group {
            if m.isPublic, let place = Place.of(m.text) {
                let shared = SharedPlace(id: m.id, place: place, by: mine ? "you" : m.name, ts: m.ts)
                VStack(alignment: .trailing, spacing: 4) {
                    PlaceRow(shared: shared, me: loc.location?.spot, now: Date())
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture { if place.spot != nil { findingPlace = shared } }
                    if let delivery { StatusLine(time: nil, delivery: delivery).padding(.horizontal, 6) }
                }
            } else if let c = CheckIn.of(m.text) {
                VStack(alignment: .trailing, spacing: 4) {
                    CheckInRow(checkIn: c, name: mine ? nil : m.name, time: time, battery: CheckIn.battery(in: m.text),
                               needs: CheckIn.needs(in: m.text), people: CheckIn.people(in: m.text), spot: CheckIn.spot(in: m.text))
                    if let delivery { StatusLine(time: nil, delivery: delivery).padding(.horizontal, 6).onTapGesture(perform: showReaders) }
                }
            } else if let v = Vouch.of(m.text) {
                VStack(alignment: .trailing, spacing: 4) {
                    VouchRow(vouch: v, by: mine ? "you" : m.name, time: time)
                    if let delivery { StatusLine(time: nil, delivery: delivery).padding(.horizontal, 6).onTapGesture(perform: showReaders) }
                }
            } else if let a = AreYouSafe.of(m.text) {
                AskRow(ask: a, from: mine ? nil : m.name, time: time, delivery: delivery,
                       canAnswer: !mine && a.isFor(myName) && !answered(after: m.ts), sending: engine.checkInSending != nil) { c in
                    if c == .safe { let e = engine; e.checkIn(.safe) { nav.toast(e.queuedToast("“I'm safe”")) } }
                    else { nav.sheet = .help }
                }
            } else {
                Bubble(text: m.photo == nil ? m.text : Photo.caption(m.text), mine: mine,
                       name: newRun && !mine ? m.name : nil, time: time,
                       delivery: delivery, tapStatus: showReaders, photo: m.photo) {
                    if let p = m.photo {
                        viewing = ViewedPhoto(id: m.id, jpeg: p, caption: Photo.caption(m.text), from: mine ? "You" : m.name)
                    }
                }
            }
        }
        .padding(.top, newRun && !first ? 10 : 0)
        .contextMenu { moderationMenu(m, mine: mine) } // hold: Block, Report on Everyone, Remove your place
        .id(m.id)
    }

    /// Shrinks a picked or taken photo and opens the send sheet.
    private func prepare(_ image: UIImage?) {
        guard let image else { return }
        guard let jpeg = PhotoShrinker.jpeg(image), let small = UIImage(data: jpeg) else { photoFailed = true; return }
        pending = PendingPhoto(jpeg: jpeg, image: small)
    }

    private func send() {
        let d = drafts.binding(channel)
        let t = String(d.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !t.isEmpty else { return }
        d.wrappedValue = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if !engine.send(t, isPublic: toPublic) { tooLong = true }
    }
}

/// Your group or everyone, with how many new messages each has.
struct ChannelSwitch: View {
    @Binding var toPublic: Bool
    let groupName: String
    var groupNew = 0
    var everyoneNew = 0

    var body: some View {
        HStack(spacing: 4) {
            segment(groupName, new: groupNew, selected: !toPublic) { toPublic = false }
            segment("Everyone", new: everyoneNew, selected: toPublic) { toPublic = true }
        }
        .padding(4).background(Capsule().fill(Theme.tile))
        .animation(.easeOut(duration: 0.15), value: toPublic)
    }

    private func segment(_ title: String, new: Int, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).scaledFont(15, .semibold).lineLimit(1)
                if new > 0 && !selected {
                    Text(new > 99 ? "99+" : "\(new)").scaledFont(12, .bold).foregroundStyle(Color.black)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.white, in: Capsule())
                }
            }
            .foregroundStyle(selected ? Color.black : Theme.dim)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Capsule().fill(selected ? Color.white : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + (new > 0 && !selected ? ", \(new) new" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One message. Yours are white on the right; others are dark grey on the left with their name above.
struct Bubble: View {
    let text: String
    let mine: Bool
    var name: String? = nil
    var time: String? = nil
    var delivery: Delivery? = nil
    var tapStatus: () -> Void = {}
    var photo: Data? = nil
    var tapPhoto: () -> Void = {}
    var isError = false
    var busy = false

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if let name { Text(name).scaledFont(13, .semibold).foregroundStyle(Theme.dim).padding(.horizontal, 6) }
            if let photo, let ui = PhotoShrinker.received(photo) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(uiImage: ui).resizable().scaledToFit().frame(maxWidth: 250)
                    if !text.isEmpty {
                        Text(text).scaledFont(17).foregroundStyle(mine ? Color.black : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
                .frame(maxWidth: 250, alignment: .leading)
                .background(mine ? Color.white : Theme.tile)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onTapGesture(perform: tapPhoto)
                .accessibilityLabel(text.isEmpty ? "Photo" : "Photo: \(text)")
                .accessibilityAddTraits(.isButton)
            } else {
            Group {
                if busy && text.isEmpty { Text("Thinking…").foregroundStyle(Theme.dim) }
                else { Text(text).textSelection(.enabled) }
            }
            .scaledFont(17)
            .foregroundStyle(mine ? Color.black : (isError ? Theme.help : Theme.text))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(mine ? Color.white : Theme.tile, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            if time != nil || delivery != nil {
                StatusLine(time: time, delivery: delivery).padding(.horizontal, 6).onTapGesture(perform: tapStatus)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 48)
    }
}

/// Time and, for your own messages, where the message is: waiting, sent, or delivered to whom.
struct StatusLine: View {
    let time: String?
    let delivery: Delivery?

    var body: some View {
        HStack(spacing: 4) {
            if let time { Text(time) }
            if let delivery {
                if time != nil { Text("·") }
                Image(systemName: delivery.symbol).scaledFont(10, .bold)
                Text(delivery.label)
            }
        }
        .scaledFont(12).lineLimit(1)
        .foregroundStyle(delivery.map { if case .delivered = $0 { return Theme.dim } else { return Theme.faint } } ?? Theme.faint)
    }
}

extension Delivery {
    var symbol: String {
        switch self {
        case .waiting: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .waiting: return "Waiting for a phone or internet"
        case .sent: return "Sent"
        case .delivered(let r):
            let n = r.map(\.name)
            if n.count == 1 { return "Delivered to \(n[0])" }
            if n.count == 2 { return "Delivered to \(n[0]) and \(n[1])" }
            return "Delivered to \(n[0]), \(n[1]) and \(n.count - 2) more"
        }
    }
}

struct ReaderList: Identifiable { let id: String; let readers: [Reader] }
struct ViewedPhoto: Identifiable { let id: String; let jpeg: Data; let caption: String; let from: String }

/// Everyone whose phone confirmed one of your messages.
struct DeliveredSheet: View {
    let readers: [Reader]

    var body: some View {
        SheetPage(title: "Delivered") {
            VStack(spacing: 0) {
                ForEach(readers, id: \.id) { r in
                    HStack {
                        Text(r.name).scaledFont(17, .semibold).foregroundStyle(Theme.text)
                        Spacer()
                        Text(ChatTime.stamp(r.ts)).scaledFont(15).foregroundStyle(Theme.dim)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    if r.id != readers.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 20) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("Delivered means their phone got the message. It doesn't mean they have read it.")
                .scaledFont(14).foregroundStyle(Theme.dim)
        }
    }
}

/// "Injured · Need water · 3 people": what a check-in or report says someone needs.
func needsText(_ needs: Set<Need>, people: Int?) -> String {
    var parts = Need.allCases.filter(needs.contains).map(\.label)
    if let people, people > 1 { parts.append("\(people) people") }
    return parts.joined(separator: " · ")
}

/// A check-in in the chat: a green "is safe" or red "needs help" card, with needs, head count and Plus Code.
struct CheckInRow: View {
    let checkIn: CheckIn
    let name: String? // nil = you
    let time: String
    var battery: Int? = nil
    var needs: Set<Need> = []
    var people: Int? = nil
    var spot: Spot? = nil

    var body: some View {
        let safe = checkIn == .safe
        let extra = needsText(needs, people: people)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: safe ? "checkmark.shield.fill" : "sos").scaledFont(18, .bold).foregroundStyle(checkIn.color)
                Text(name.map { safe ? "\($0) is safe" : "\($0) needs help" } ?? (safe ? "You're safe" : "You asked for help"))
                    .scaledFont(16, .semibold).foregroundStyle(Theme.text)
                Spacer()
                if let battery { BatteryLabel(percent: battery) }
                Text(time).scaledFont(13).foregroundStyle(Theme.dim)
            }
            if !extra.isEmpty { Text(extra).scaledFont(15, .semibold).foregroundStyle(Theme.text).padding(.leading, 36) }
            if let spot { PlusCodeLabel(spot: spot).padding(.leading, 36) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(checkIn.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Someone's report about another person: neutral, dashed, "reported by", never like that person's own check-in.
struct VouchRow: View {
    let vouch: Vouch
    let by: String
    let time: String

    var body: some View {
        let safe = vouch.status == .safe
        let extra = needsText(vouch.needs, people: vouch.people)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark").scaledFont(18, .bold).foregroundStyle(vouch.status.color)
                Text("\(vouch.subject) \(safe ? "is safe" : "needs help")").scaledFont(16, .semibold).foregroundStyle(Theme.text)
                Spacer()
                Text(time).scaledFont(13).foregroundStyle(Theme.dim)
            }
            Text("Reported by \(by)").scaledFont(14).foregroundStyle(Theme.dim).padding(.leading, 36)
            if !extra.isEmpty { Text(extra).scaledFont(15, .semibold).foregroundStyle(Theme.text).padding(.leading, 36) }
            if let s = vouch.spot { PlusCodeLabel(spot: s).padding(.leading, 36) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(vouch.status.color.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }
}

/// "Is everyone safe?" in the chat, with one-tap answers for whoever it is for.
struct AskRow: View {
    let ask: AreYouSafe
    let from: String? // nil = you asked
    let time: String
    let delivery: Delivery?
    let canAnswer: Bool
    let sending: Bool
    let answer: (CheckIn) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.bubble.fill").scaledFont(18, .bold).foregroundStyle(Theme.text)
                Text(title).scaledFont(16, .semibold).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(time).scaledFont(13).foregroundStyle(Theme.dim)
            }
            if canAnswer {
                HStack(spacing: 10) {
                    Button { answer(.safe) } label: { Label(sending ? "Sending…" : "I'm safe", systemImage: "checkmark.shield.fill") }
                        .buttonStyle(GhostButton()).disabled(sending)
                    Button { answer(.help) } label: { Label("I need help", systemImage: "sos") }
                        .buttonStyle(GhostButton()).disabled(sending)
                }
            }
            if let delivery { StatusLine(time: nil, delivery: delivery) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var title: String {
        guard let from else { return ask.to.map { "You asked \($0) if they are safe" } ?? "You asked: is everyone safe?" }
        return ask.to.map { "\(from) asks \($0): are you safe?" } ?? "\(from) asks: is everyone safe?"
    }
}

/// "8FQFF57R+M2": a position people can read out or type into any map app. Tap to copy.
struct PlusCodeLabel: View {
    let spot: Spot
    var body: some View {
        if let code = spot.plusCode {
            Button {
                UIPasteboard.general.string = code
                Nav.shared.toast("Plus Code copied")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus.viewfinder").scaledFont(12, .semibold)
                    Text(code).scaledFont(13, .semibold, design: .monospaced)
                    Image(systemName: "doc.on.doc").scaledFont(11)
                }
                .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Plus Code \(code.map(String.init).joined(separator: " ")). Copy")
        }
    }
}

/// Message field with a round send button. For Everyone it has a white outline and a megaphone.
struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    var enabled = true
    var isPublic = false
    let send: () -> Void
    private var canSend: Bool { enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("", text: $draft, prompt: Text(placeholder).foregroundColor(Theme.faint), axis: .vertical)
                .lineLimit(1...5)
                .scaledFont(17).foregroundStyle(Theme.text).tint(Theme.text)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(isPublic ? Theme.text.opacity(0.7) : .clear, lineWidth: 1.5))
                .accessibilityLabel(placeholder)
            Button(action: send) {
                Image(systemName: isPublic ? "megaphone.fill" : "arrow.up").scaledFont(isPublic ? 17 : 19, .bold)
                    .foregroundStyle(canSend ? Color.black : Theme.faint)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(canSend ? Color.white : Theme.tile))
            }
            .disabled(!canSend)
            .accessibilityLabel(isPublic ? "Send to everyone" : "Send")
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: symbol).scaledFont(28, .semibold).foregroundStyle(Theme.text)
                .frame(width: 72, height: 72).background(Circle().fill(Theme.tile))
            Text(title).scaledFont(22, .bold).foregroundStyle(Theme.text)
            Text(text).scaledFont(16).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// Sheet with a title and a Done button, used for the secondary screens.
struct SheetPage<Content: View>: View {
    let title: String
    var close = "Done" // "Cancel" where closing means not doing it
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 16) { content() }.padding(20) }
                .scrollDismissesKeyboard(.interactively)
                .background(Theme.bg.ignoresSafeArea())
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .toolbar { Button(close) { dismiss() }.fontWeight(.semibold) }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.text)
        .modifier(ToastOverlay()) // confirmations show over sheets too
    }
}
