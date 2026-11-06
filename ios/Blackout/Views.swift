import SwiftUI
import PhotosUI
import BlackoutCore

struct RootView: View {
    @AppStorage("name") private var name = ""
    @AppStorage("code") private var code = ""
    @AppStorage("groupName") private var groupName = "My group"
    @State private var engine: Engine?
    @State private var invite: PendingInvite?   // from an invite link
    @State private var confirmSwitch = false
    @State private var showInvite = false       // opens the invite sheet, e.g. right after creating a group

    var body: some View {
        Group {
            if let engine {
                MainView(engine: engine, showInvite: $showInvite)
            } else if code.isEmpty {
                SetupView(invite: invite) { n, g, c, created in
                    SavedGroups.remember(.init(name: g, code: c))
                    name = n; groupName = g; code = c
                    engine = Engine(name: n, code: c)
                    invite = nil; showInvite = created
                }
            } else {
                Theme.bg.ignoresSafeArea().onAppear { engine = Engine(name: name, code: code) }
            }
        }
        .tint(Theme.text)
        .onOpenURL { url in
            guard let i = Invite.parse(url) else { return }
            invite = PendingInvite(name: i.name, code: i.code)
            if !code.isEmpty && i.code != code { confirmSwitch = true } // already in another group: ask first
        }
        .alert("Join \(invite?.name ?? "")?", isPresented: $confirmSwitch, presenting: invite) { i in
            Button("Join") {
                if let engine { SavedGroups.switchTo(groupName: i.name, code: i.code, engine: engine) }
                invite = nil
            }
            Button("Cancel", role: .cancel) { invite = nil }
        } message: { i in
            Text("You'll see \(i.name)'s messages instead of \(groupName)'s. You can switch back in Settings.")
        }
    }
}

struct PendingInvite: Equatable { let name: String; let code: String }

// MARK: - Setup

struct SetupView: View {
    var invite: PendingInvite?
    /// name, group name, group code, and whether the group was just created
    let done: (String, String, String, Bool) -> Void
    enum Mode { case welcome, create, join }
    @State private var mode = Mode.welcome
    @State private var name = ""
    @State private var groupName = ""
    @State private var code = ""
    @FocusState private var focus: Field?
    enum Field { case name, group, code }

    private func clean(_ s: String, _ max: Int) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max)) }
    private var cleanName: String { clean(name, 20) }
    private var cleanCode: String { clean(code, 200) }

    var body: some View {
        Group {
            if let invite {
                form(title: "You're invited", subtitle: "Join \(invite.name) to message each other without internet.", back: false) {
                    nameField
                    Button("Join \(invite.name)") { done(cleanName, invite.name, invite.code, false) }
                        .buttonStyle(PrimaryButton()).disabled(cleanName.isEmpty)
                }
            } else {
                switch mode {
                case .welcome: welcome
                case .create: create
                case .join: join
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Logo(size: 150).frame(maxWidth: .infinity)
            Spacer()
            Text("Stay connected when everything goes dark.")
                .font(.system(size: 40, weight: .heavy)).tracking(-1).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Messages travel phone to phone over Bluetooth and Wi-Fi. No internet, no signal, no account.")
                .font(.system(size: 17)).foregroundStyle(Theme.dim).padding(.top, 14)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                Button { mode = .create } label: { Label("Create a group", systemImage: "plus") }.buttonStyle(PrimaryButton())
                Button { mode = .join } label: { Label("Join a group", systemImage: "qrcode.viewfinder") }.buttonStyle(SecondaryButton())
            }
            .padding(.top, 36)
            Text("Free and private. No servers, ever.").font(.footnote).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity).padding(.top, 14)
        }
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var create: some View {
        form(title: "Create a group", subtitle: "For your family, friends or building. DarkProof makes a secret code for it, then you invite people with a QR code.") {
            nameField
            InputField(label: "Group name", hint: "You can change it later.", active: focus == .group, tap: { focus = .group }) {
                TextField("", text: $groupName, prompt: Text("Family").foregroundColor(Theme.faint))
                    .focused($focus, equals: .group).submitLabel(.done)
            }
            Button("Create group") {
                let g = clean(groupName, Invite.maxGroupName)
                done(cleanName, g.isEmpty ? String("\(cleanName)'s group".prefix(Invite.maxGroupName)) : g, Invite.newCode(), true)
            }
            .buttonStyle(PrimaryButton()).disabled(cleanName.isEmpty)
        }
    }

    private var join: some View {
        form(title: "Join a group", subtitle: "Open the iPhone Camera, point it at your friend's invite QR and tap the DarkProof link. Or type their code here.") {
            nameField
            InputField(label: "Group code", hint: "Your friend finds it under Invite > Show code.", active: focus == .code, tap: { focus = .code }) {
                TextField("", text: $code, prompt: Text("XXXX-XXXX-XXXX-XXXX").foregroundColor(Theme.faint))
                    .focused($focus, equals: .code).textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            Button("Join") { done(cleanName, "Group", cleanCode, false) }
                .buttonStyle(PrimaryButton()).disabled(cleanName.isEmpty || cleanCode.count < 8)
            if !(name.isEmpty && code.isEmpty), let why = cleanName.isEmpty ? "Enter your name." :
                cleanCode.count < 8 ? "Codes have at least 8 characters." : nil {
                Text(why).font(.footnote).foregroundStyle(Theme.dim)
            }
        }
    }

    private var nameField: some View {
        InputField(label: "Your name", hint: "Shown next to your messages.", active: focus == .name, tap: { focus = .name }) {
            TextField("", text: $name, prompt: Text("Anna").foregroundColor(Theme.faint))
                .focused($focus, equals: .name).submitLabel(.done).textContentType(.givenName)
        }
    }

    private func form<C: View>(title: String, subtitle: String, back: Bool = true, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if back {
                    Button { focus = nil; mode = .welcome } label: { RoundIcon(symbol: "chevron.left") }.accessibilityLabel("Back")
                } else {
                    Logo(size: 44)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 34, weight: .heavy)).tracking(-0.5).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 17)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Labeled text field; [active] outlines it while it has focus.
struct InputField<Field: View>: View {
    let label: String
    var hint = ""
    var active = false
    var tap: () -> Void = {} // focuses the field when the box around the text is tapped
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(label)
            field()
                .font(.system(size: 17)).foregroundStyle(Theme.text).tint(Theme.text)
                .padding(.horizontal, 18).frame(minHeight: 54)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(active ? Theme.text.opacity(0.6) : .clear, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture(perform: tap)
            if !hint.isEmpty { Text(hint).font(.footnote).foregroundStyle(Theme.dim) }
        }
    }
}

// MARK: - Main

struct MainView: View {
    enum Sheet: String, Identifiable { case invite, group, radio; var id: String { rawValue } }
    @ObservedObject var engine: Engine
    @Binding var showInvite: Bool
    @AppStorage("groupName") private var groupName = "My group"
    @AppStorage("code") private var code = ""
    @State private var tab = 0
    @State private var sheet: Sheet?

    var body: some View {
        TabView(selection: $tab) {
            HomeView(engine: engine, open: { sheet = $0 }, showPeople: { tab = 3 })
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            ChatView(engine: engine).tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }.tag(1)
            PlacesView(engine: engine).tabItem { Label("Places", systemImage: "mappin.and.ellipse") }.tag(2)
            PeopleView(engine: engine, open: { sheet = $0 }).tabItem { Label("People", systemImage: "person.2.fill") }.tag(3)
            AiView(engine: engine).tabItem { Label("Ask", systemImage: "sparkles") }.tag(4)
        }
        .tint(Theme.text)
        .sheet(item: $sheet) { s in
            switch s {
            case .invite: InviteSheet(groupName: groupName, code: code)
            case .group:
                GroupSheet(engine: engine) { // a new group was created: invite people to it
                    sheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sheet = .invite }
                }
            case .radio: RadioView(engine: engine)
            }
        }
        .onAppear { if showInvite { showInvite = false; sheet = .invite } } // right after creating a group
        .onChange(of: showInvite) { open in if open { showInvite = false; sheet = .invite } }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var engine: Engine
    let open: (MainView.Sheet) -> Void
    let showPeople: () -> Void
    @AppStorage("groupName") private var groupName = "My group"
    @State private var details = false
    @State private var confirmHelp = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { t in
            let people = Person.all(in: engine.messages, me: engine.deviceId)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    hero
                    if engine.phones == 0 { ConnectionHelp(engine: engine) }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            QuickAction(symbol: "checkmark.shield.fill", label: "I'm safe", tint: Theme.safe) { engine.checkIn(.safe) }
                            QuickAction(symbol: "sos", label: "Need help", tint: Theme.help) { confirmHelp = true }
                            QuickAction(symbol: "qrcode", label: "Invite", tint: Theme.text) { open(.invite) }
                            QuickAction(symbol: "antenna.radiowaves.left.and.right", label: "Radio", tint: Theme.text) { open(.radio) }
                        }
                        LastCheckIn(engine: engine, now: t.date).padding(.horizontal, 4)
                    }
                    SectionTitle(title: "Your people", action: people.count > 3 ? "See all" : nil, tap: showPeople)
                    if people.isEmpty {
                        NoPeopleCard(groupName: groupName) { open(.invite) }
                    } else {
                        PeopleList(people: Array(people.prefix(3)), engine: engine, now: t.date)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
        }
        .helpConfirmation($confirmHelp, groupName: groupName) { engine.checkIn(.help) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Logo(size: 30)
            Button { open(.group) } label: {
                HStack(spacing: 5) {
                    Text(groupName).font(.system(size: 22, weight: .bold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.dim)
                }
                .foregroundStyle(Theme.text)
            }
            .accessibilityHint("Switch or rename the group")
            Spacer()
            Button { open(.group) } label: { RoundIcon(symbol: "gearshape.fill") }.accessibilityLabel("Settings")
        }
    }

    private var linkSummary: String {
        if engine.phones == 0 { return "Keep DarkProof open. Your messages wait and go out as soon as a phone is in range." }
        var via: [String] = []
        if engine.bluetoothLinks > 0 { via.append("Bluetooth") }
        if engine.wifiLinks > 0 { via.append("Wi-Fi") }
        if engine.radioLinked { via.append("LoRa radio") }
        let how = via.isEmpty ? "" : "Over \(ListFormatter.localizedString(byJoining: via)). "
        return how + "Your messages hop from phone to phone."
    }

    private var hero: some View {
        let connected = engine.phones > 0
        return Button { withAnimation(.easeOut(duration: 0.2)) { details.toggle() } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(connected ? Theme.safe : Theme.dim).frame(width: 9, height: 9)
                    Text(connected ? "Connected" : "Looking for phones").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(connected ? Theme.safe : Theme.dim)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(details ? 180 : 0))
                }
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text("\(engine.phones)").font(.system(size: 84, weight: .heavy)).tracking(-3).foregroundStyle(Theme.text)
                    Text(engine.phones == 1 ? "phone\nin range" : "phones\nin range")
                        .font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.dim).padding(.bottom, 12)
                }
                Text(linkSummary).font(.system(size: 15)).foregroundStyle(Theme.dim).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if details {
                    VStack(alignment: .leading, spacing: 4) { ForEach(engine.statusLines, id: \.self) { Text($0) } }
                        .font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 10)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(VaultShape().fill(Theme.card))
            .contentShape(VaultShape())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows connection details")
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
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 44, height: 44).background(Circle().fill(tint.opacity(0.14)))
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressScale())
    }
}

/// Shrinks a custom-drawn button a little while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Chat

struct ChatView: View {
    @ObservedObject var engine: Engine
    @State private var draft = ""
    @State private var tooLong = false
    @State private var toPublic = false
    @State private var readers: ReaderList?
    @State private var findingPlace: SharedPlace?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var pending: PendingPhoto?
    @State private var viewing: ViewedPhoto?
    @State private var photoFailed = false
    @ObservedObject private var loc = LocationService.shared
    @AppStorage("groupName") private var groupName = "My group"
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    private var shown: [Message] { engine.messages.filter { $0.isPublic == toPublic } }

    var body: some View {
        let list = shown
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenTitle(title: toPublic ? "Everyone" : groupName,
                            subtitle: engine.phones == 0 ? "No one in range right now" :
                                "\(engine.phones) \(engine.phones == 1 ? "phone" : "phones") in range")
                ChannelSwitch(toPublic: $toPublic, groupName: groupName)
                Text(toPublic ? "Anyone with DarkProof nearby can read these." : "Only people in \(groupName) can read these.")
                    .font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)

            if list.isEmpty {
                EmptyState(symbol: toPublic ? "megaphone.fill" : "bubble.left.and.bubble.right.fill",
                           title: "No messages yet",
                           text: toPublic ? "Messages for everyone nearby show up here, from any group."
                                          : "Write the first one. It reaches everyone in \(groupName) who is in range, or later when they are.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                                let mine = m.sender == engine.deviceId
                                let prev = i > 0 ? list[i - 1] : nil
                                let newRun = prev == nil || prev!.sender != m.sender || prev!.name != m.name
                                    || CheckIn.of(prev!.text) != nil
                                let time = Self.time.string(from: Date(timeIntervalSince1970: Double(m.ts) / 1000))
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
                                            CheckInRow(checkIn: c, name: mine ? nil : m.name, time: time, battery: CheckIn.battery(in: m.text))
                                            if let delivery { StatusLine(time: nil, delivery: delivery).padding(.horizontal, 6).onTapGesture(perform: showReaders) }
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
                                .padding(.top, newRun && i > 0 ? 10 : 0)
                                .id(m.id)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: engine.messages.count) { _ in
                        if let last = shown.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onChange(of: toPublic) { _ in
                        DispatchQueue.main.async { if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onAppear { // open on the newest messages, once the list has been laid out
                        DispatchQueue.main.async { if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                if !toPublic {
                    Menu {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { takingPhoto = true } label: { Label("Take photo", systemImage: "camera") }
                        }
                        Button { choosingPhoto = true } label: { Label("Choose photo", systemImage: "photo.on.rectangle") }
                    } label: {
                        Image(systemName: "camera.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                            .frame(width: 50, height: 50).background(Circle().fill(Theme.tile))
                    }
                    .accessibilityLabel("Send a photo")
                }
                Composer(draft: $draft, placeholder: toPublic ? "Message everyone" : "Message \(groupName)", send: send)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(item: $readers) { DeliveredSheet(readers: $0.readers) }
        .sheet(item: $findingPlace) { FindSheet(place: $0.place, by: $0.by, ts: $0.ts) }
        .sheet(item: $viewing) { PhotoViewer(jpeg: $0.jpeg, caption: $0.caption, from: $0.from) }
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
        .alert("Too long for LoRa: it will travel only over Bluetooth and Wi-Fi", isPresented: $tooLong) { Button("OK", role: .cancel) {} }
    }

    /// Shrinks a picked or taken photo and opens the send sheet.
    private func prepare(_ image: UIImage?) {
        guard let image else { return }
        guard let jpeg = PhotoShrinker.jpeg(image), let small = UIImage(data: jpeg) else { photoFailed = true; return }
        pending = PendingPhoto(jpeg: jpeg, image: small)
    }

    private func send() {
        let t = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !t.isEmpty else { return }
        draft = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if !engine.send(t, isPublic: toPublic) && engine.lora.connected { tooLong = true }
    }
}

/// Your group or everyone nearby.
struct ChannelSwitch: View {
    @Binding var toPublic: Bool
    let groupName: String

    var body: some View {
        HStack(spacing: 4) {
            segment(groupName, selected: !toPublic) { toPublic = false }
            segment("Everyone", selected: toPublic) { toPublic = true }
        }
        .padding(4).background(Capsule().fill(Theme.tile))
        .animation(.easeOut(duration: 0.15), value: toPublic)
    }

    private func segment(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                .foregroundStyle(selected ? Color.black : Theme.dim)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Capsule().fill(selected ? Color.white : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
            if let name { Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim).padding(.horizontal, 6) }
            if let photo, let ui = UIImage(data: photo) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(uiImage: ui).resizable().scaledToFit().frame(maxWidth: 250)
                    if !text.isEmpty {
                        Text(text).font(.system(size: 17)).foregroundStyle(mine ? Color.black : Theme.text)
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
            .font(.system(size: 17))
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
                Image(systemName: delivery.symbol).font(.system(size: 10, weight: .bold))
                Text(delivery.label)
            }
        }
        .font(.system(size: 12)).lineLimit(1)
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
        case .waiting: return "Waiting for a phone in range"
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
                        Text(r.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(ChatView.time.string(from: Date(timeIntervalSince1970: Double(r.ts) / 1000)))
                            .font(.system(size: 15)).foregroundStyle(Theme.dim)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    if r.id != readers.last?.id { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 20) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("Delivered means their phone got the message. It doesn't mean they have read it.")
                .font(.system(size: 14)).foregroundStyle(Theme.dim)
        }
    }
}

/// A check-in in the chat: a green "is safe" or red "needs help" card.
struct CheckInRow: View {
    let checkIn: CheckIn
    let name: String? // nil = you
    let time: String
    var battery: Int? = nil

    var body: some View {
        let safe = checkIn == .safe
        HStack(spacing: 12) {
            Image(systemName: safe ? "checkmark.shield.fill" : "sos").font(.system(size: 18, weight: .bold)).foregroundStyle(checkIn.color)
            Text(name.map { safe ? "\($0) is safe" : "\($0) needs help" } ?? (safe ? "You're safe" : "You asked for help"))
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            if let battery { BatteryLabel(percent: battery) }
            Text(time).font(.system(size: 13)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(checkIn.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Message field with a round send button.
struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    var enabled = true
    let send: () -> Void
    private var canSend: Bool { enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("", text: $draft, prompt: Text(placeholder).foregroundColor(Theme.faint), axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 17)).foregroundStyle(Theme.text).tint(Theme.text)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(canSend ? Color.black : Theme.faint)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(canSend ? Color.white : Theme.tile))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
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
            Image(systemName: symbol).font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 72, height: 72).background(Circle().fill(Theme.tile))
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 16)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - Ask (offline AI)

struct AiView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var ai = LocalAi.shared
    @State private var draft = ""
    @State private var choosingModel = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ScreenTitle(title: "Ask", subtitle: "Offline assistant on this iPhone")
                    Spacer()
                    Button("New") { ai.newConversation() }.buttonStyle(GhostButton())
                        .disabled(ai.busy || ai.conversation.isEmpty)
                }
                Button { choosingModel = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                        Text(ai.selected.title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(GhostButton())
                Text("It works with no internet and can be wrong. Double-check anything important.")
                    .font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)

            if !ai.selectedReady {
                VStack {
                    Card {
                        Text("No AI model on this iPhone").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                        Text("Download one while you still have internet. It stays on the phone and works offline afterwards.")
                            .font(.system(size: 16)).foregroundStyle(Theme.dim)
                        Button("Choose a model") { choosingModel = true }.buttonStyle(PrimaryButton())
                    }
                    Spacer()
                }
                .padding(20)
            } else if ai.conversation.isEmpty {
                EmptyState(symbol: "sparkles", title: "Ask anything",
                           text: "First aid, water, staying warm, what to pack. Or summarize what your group said.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(ai.conversation.enumerated()), id: \.element.id) { i, t in
                                let mine = t.role == "user"
                                let newRun = i == 0 || ai.conversation[i - 1].role != t.role
                                Bubble(text: t.text, mine: mine, name: newRun && !mine ? "Assistant" : nil, isError: t.isError,
                                       busy: ai.busy && !mine && i == ai.conversation.count - 1)
                                    .padding(.top, newRun && i > 0 ? 10 : 0)
                                    .id(t.id)
                            }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: ai.conversation.last?.text) { _ in
                        if let last = ai.conversation.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        DispatchQueue.main.async { if let last = ai.conversation.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Button { summarize() } label: { Label("Summarize group messages", systemImage: "text.alignleft") }
                    .buttonStyle(GhostButton())
                    .disabled(ai.busy || !ai.selectedReady || engine.messages.isEmpty)
                Composer(draft: $draft, placeholder: ai.busy ? "Thinking…" : "Ask a question",
                         enabled: !ai.busy && ai.selectedReady) {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { draft = ""; ai.send(t) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $choosingModel) { ModelPicker(ai: ai) }
    }

    private func summarize() {
        // Recent group messages, kept within what the model can read at once (about 4 characters per token).
        var h = engine.messages.suffix(40).map {
            "\(ChatView.time.string(from: Date(timeIntervalSince1970: Double($0.ts) / 1000))) \($0.name): \($0.text.prefix(300))"
        }.joined(separator: "\n")
        h = String(h.suffix(Int(ai.selected.context) * 2))
        if !h.isEmpty {
            ai.send("Summarize these emergency messages from my group: who is safe, who is asking for help, and what is missing. Do not make anything up.\n\n\(h)")
        }
    }
}

/// Sheet with a title and a Done button, used for the secondary screens.
struct SheetPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 16) { content() }.padding(20) }
                .scrollDismissesKeyboard(.interactively)
                .background(Theme.bg.ignoresSafeArea())
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.text)
    }
}

struct ModelPicker: View {
    @ObservedObject var ai: LocalAi

    var body: some View {
        SheetPage(title: "AI model") {
            Text("Models run entirely on this iPhone. Bigger ones answer better but slower.")
                .font(.system(size: 15)).foregroundStyle(Theme.dim)
            ForEach(LocalAi.catalog) { m in row(m) }
        }
    }

    private func row(_ m: AiModel) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Text(m.title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                if ai.selectedId == m.id && ai.states[m.id] == .ready { Chip("In use", Theme.safe) }
            }
            Text(m.detail).font(.system(size: 15)).foregroundStyle(Theme.text)
            Text("\(size) · \(m.license)").font(.system(size: 13)).foregroundStyle(Theme.dim)
            switch ai.states[m.id] ?? .missing {
            case .ready:
                HStack {
                    if ai.selectedId != m.id { Button("Use this model") { ai.select(m) }.buttonStyle(GhostButton()) }
                    Spacer()
                    Button("Delete", role: .destructive) { ai.delete(m) }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.help).disabled(ai.busy)
                }
            case .missing:
                Button("Download \(size)") { ai.download(m) }.buttonStyle(PrimaryButton()).disabled(ai.isDownloading)
            case .downloading(let p):
                ProgressLine(progress: p)
                Text("Downloading \(Int(p * 100))%. Keep the app open.").font(.system(size: 13)).foregroundStyle(Theme.dim)
            case .verifying:
                Text("Checking the download…").font(.system(size: 13)).foregroundStyle(Theme.dim)
            case .failed(let why):
                Text("Download failed: \(why)").font(.footnote).foregroundStyle(Theme.help)
                Button("Try again") { ai.download(m) }.buttonStyle(GhostButton()).disabled(ai.isDownloading)
            }
        }
    }
}

// MARK: - Radio

struct RadioView: View {
    struct Radio: Identifiable { let id: UUID; let name: String }
    @ObservedObject var engine: Engine
    @State private var radios: [Radio] = []
    @State private var searching = false
    @State private var note = ""

    private var statusText: String {
        (engine.status["3-lora"] ?? "LoRa: no radio").replacingOccurrences(of: "LoRa: ", with: "")
    }

    var body: some View {
        SheetPage(title: "LoRa radio") {
            Card {
                HStack {
                    Text("Radio").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Chip(engine.radioLinked ? "Linked" : "Not linked", engine.radioLinked ? Theme.safe : Theme.dim)
                }
                Text(statusText).font(.system(size: 15)).foregroundStyle(Theme.dim)
                Button(searching ? "Search again" : "Search for radios") {
                    radios = []; searching = true
                    engine.lora.scan { id, name in
                        if !radios.contains(where: { $0.id == id }) { radios.append(Radio(id: id, name: name)) }
                    }
                }
                .buttonStyle(PrimaryButton())
                if searching && radios.isEmpty {
                    Text("Looking for radios nearby… Turn the radio on and keep it next to the phone.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
                ForEach(radios) { r in
                    Button {
                        engine.lora.select(r.id)
                        note = "Connecting. If asked, enter the PIN shown on the radio."
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(r.name).font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Text("Connect").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.dim)
                        }
                        .foregroundStyle(Theme.text)
                        .padding(16)
                        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(Theme.dim) }
            }
            Card {
                info("What it does", "A Meshtastic LoRa radio pairs with this iPhone over Bluetooth and reaches other radios kilometers away: about 2–10 km in a city, more in open country or from high places. Every radio also relays for the others.")
                info("Limits", "Short messages only (about 160 characters), one every 20 seconds, and only from the last 30 minutes.")
                info("You need", "A Meshtastic radio set to the EU_868 region, for example a Heltec V3.")
            }
        }
    }

    private func info(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 15)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
/// Debug builds only: connects to the Android app's LAN test listener over TCP.
struct LanTestView: View {
    @ObservedObject var engine: Engine
    @State private var address = "127.0.0.1:7777"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: "LAN test", subtitle: "Debug build only")
                Card {
                    Text("Connects over TCP to the Android app's LAN test listener, to test chat, relaying, and encryption between the two apps. This does NOT test Bluetooth or Apple peer-to-peer.")
                        .font(.system(size: 15)).foregroundStyle(Theme.text)
                    Text("From the iOS Simulator, 127.0.0.1:7777 reaches an Android emulator after running on the computer:\nadb -s <emulator> forward tcp:7777 tcp:7777")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
                    InputField(label: "Host:port") {
                        TextField("", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button("Connect") {
                        let a = address.trimmingCharacters(in: .whitespaces)
                        if let i = a.lastIndex(of: ":"), let port = UInt16(a[a.index(after: i)...]), i > a.startIndex {
                            engine.lan.connect(host: String(a[..<i]), port: port)
                        }
                    }
                    .buttonStyle(PrimaryButton())
                    Button("Stop LAN test") { engine.lan.stop() }.buttonStyle(GhostButton())
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}
#endif
