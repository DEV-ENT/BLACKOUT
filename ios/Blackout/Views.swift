import SwiftUI
import BlackoutCore

struct RootView: View {
    @AppStorage("name") private var name = ""
    @AppStorage("code") private var code = ""
    @State private var engine: Engine?

    var body: some View {
        Group {
            if let engine {
                MainView(engine: engine)
            } else if code.isEmpty {
                SetupView { n, c in name = n; code = c; engine = Engine(name: n, code: c) }
            } else {
                Theme.bg.ignoresSafeArea().onAppear { engine = Engine(name: name, code: code) }
            }
        }
        .tint(Theme.amber)
    }
}

// MARK: - Setup

struct SetupView: View {
    let join: (String, String) -> Void
    @State private var name = ""
    @State private var code = ""
    @FocusState private var focus: Field?
    enum Field { case name, code }

    private var cleanName: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20)) }
    private var cleanCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var missing: String? {
        if cleanName.isEmpty { return "Enter your name." }
        if cleanCode.count < 8 { return "The group code needs at least 8 characters (\(cleanCode.count) so far)." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Radar(phones: 3, radio: true).frame(width: 132, height: 132).frame(maxWidth: .infinity)
                    .accessibilityHidden(true).padding(.top, 12)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        Text("BLACKOUT").tracking(5)
                        Cursor()
                    }
                    .font(Theme.mono(36, .heavy)).foregroundStyle(Theme.text)
                    Text("Messages without internet or cell signal.")
                        .font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                }
                Card {
                    Kicker("How it works", color: Theme.amber)
                    step("01", "Phones nearby connect on their own, over Bluetooth and Wi-Fi.")
                    step("02", "Every phone passes messages on, so they hop to people out of range.")
                    step("03", "Only people with your group code can read your group.")
                }
                InputField(label: "Your name", hint: "Shown next to your messages.", active: focus == .name, tap: { focus = .name }) {
                    TextField("", text: $name).focused($focus, equals: .name).submitLabel(.next).onSubmit { focus = .code }
                }
                InputField(label: "Group code", hint: "Agree on it in person. Anyone who knows it can read the group.",
                           active: focus == .code, tap: { focus = .code }) {
                    TextField("", text: $code).focused($focus, equals: .code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.join).onSubmit { if missing == nil { join(cleanName, cleanCode) } }
                }
                VStack(spacing: 10) {
                    Button("Join the mesh") { join(cleanName, cleanCode) }
                        .buttonStyle(PrimaryButton()).disabled(missing != nil)
                    if let missing, !(name.isEmpty && code.isEmpty) {
                        Text(missing).font(.footnote).foregroundStyle(Theme.dim)
                    }
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n).font(Theme.mono(13, .bold)).foregroundStyle(Theme.amber)
            Text(text).font(.subheadline).foregroundStyle(Theme.text)
        }
    }
}

/// Labeled text field in the console style; [active] highlights it while it has focus.
struct InputField<Field: View>: View {
    let label: String
    var hint = ""
    var active = false
    var tap: () -> Void = {} // focuses the field when the box around the text is tapped
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(label, color: active ? Theme.amber : Theme.dim)
            field()
                .font(.body).foregroundStyle(Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(active ? Theme.amber : Theme.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture(perform: tap)
            if !hint.isEmpty { Text(hint).font(.footnote).foregroundStyle(Theme.dim) }
        }
    }
}

// MARK: - Main

struct MainView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            MeshHeader(engine: engine)
            TabView {
                tab(ChatView(engine: engine)).tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                tab(AiView(engine: engine)).tabItem { Label("AI", systemImage: "sparkles") }
                tab(RadioView(engine: engine)).tabItem { Label("Radio", systemImage: "antenna.radiowaves.left.and.right") }
                #if DEBUG
                tab(LanTestView(engine: engine)).tabItem { Label("LAN test", systemImage: "network") }
                #endif
            }
            .tint(Theme.amber)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func tab<V: View>(_ v: V) -> some View {
        v.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
    }
}

/// Top bar: how many phones are linked right now, per transport. Tap for the detailed status lines.
struct MeshHeader: View {
    @ObservedObject var engine: Engine
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { open.toggle() } } label: {
                HStack(spacing: 12) {
                    Radar(phones: engine.phones, radio: engine.radioLinked, sweeping: engine.phones == 0)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 0) {
                            if engine.phones == 0 { Text("SEARCHING"); Cursor() }
                            else { Text("\(engine.phones) PHONE\(engine.phones == 1 ? "" : "S") LINKED") }
                        }
                        .font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                        HStack(spacing: 6) {
                            Chip("BT \(engine.bluetoothLinks)", engine.bluetoothLinks > 0 ? Theme.live : Theme.dim)
                            Chip("Wi-Fi \(engine.wifiLinks)", engine.wifiLinks > 0 ? Theme.live : Theme.dim)
                            Chip(engine.radioLinked ? "LoRa on" : "LoRa off", engine.radioLinked ? Theme.amber : Theme.dim)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.footnote.weight(.bold)).foregroundStyle(Theme.dim)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows connection details")
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(engine.statusLines, id: \.self) { Text($0) }
                    Text("Messages hop from phone to phone. Keep Blackout running near other phones.").padding(.top, 4)
                }
                .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// MARK: - Chat

struct ChatView: View {
    @ObservedObject var engine: Engine
    @State private var draft = ""
    @State private var tooLong = false
    @State private var toPublic = false
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        VStack(spacing: 0) {
            if engine.messages.isEmpty {
                EmptyState(title: "No messages yet",
                           text: "Messages from your group and the Public channel show up here. Keep Blackout open near other phones: they connect on their own.") {
                    Radar(phones: engine.phones, radio: engine.radioLinked).frame(width: 150, height: 150)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(engine.messages.enumerated()), id: \.element.id) { i, m in
                                let mine = m.sender == engine.deviceId
                                let prev = i > 0 ? engine.messages[i - 1] : nil
                                let newRun = prev == nil || prev!.sender != m.sender || prev!.name != m.name || prev!.isPublic != m.isPublic
                                Bubble(text: m.text, mine: mine, name: newRun && !mine ? m.name : nil,
                                       time: Self.time.string(from: Date(timeIntervalSince1970: Double(m.ts) / 1000)),
                                       isPublic: m.isPublic && newRun)
                                    .padding(.top, newRun && i > 0 ? 10 : 0)
                                    .id(m.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: engine.messages.count) { _ in
                        if let last = engine.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onAppear { // open on the newest messages, once the list has been laid out
                        DispatchQueue.main.async { if let last = engine.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ChannelPill(title: "Group", selected: !toPublic, color: Theme.amber) { toPublic = false }
                    ChannelPill(title: "Public", selected: toPublic, color: Theme.open) { toPublic = true }
                    Spacer()
                    Text(toPublic ? "Everyone with Blackout can read it" : "Only your group can read it")
                        .font(.caption).foregroundStyle(toPublic ? Theme.open : Theme.dim)
                }
                Composer(draft: $draft, placeholder: toPublic ? "Message to everyone" : "Message to your group",
                         accent: toPublic ? Theme.open : Theme.amber, enabled: true, send: send)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .alert("Too long for LoRa: it will travel only over Bluetooth and Wi-Fi", isPresented: $tooLong) { Button("OK", role: .cancel) {} }
    }

    private func send() {
        let t = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !t.isEmpty else { return }
        draft = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if !engine.send(t, isPublic: toPublic) && engine.lora.connected { tooLong = true }
    }
}

/// One message. Your own are amber on the right; others are grey on the left with their name above.
struct Bubble: View {
    let text: String
    let mine: Bool
    var name: String? = nil
    var time: String? = nil
    var isPublic = false
    var isError = false
    var busy = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 56) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if name != nil || isPublic {
                    HStack(spacing: 6) {
                        if isPublic { Chip("Public", Theme.open) }
                        if let name { Text(name).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.dim) }
                    }
                    .padding(.horizontal, 4)
                }
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text(text).textSelection(.enabled)
                        if busy { Cursor(color: Theme.text) }
                    }
                    .font(.body)
                    .foregroundStyle(mine ? Color.black : (isError ? Theme.alert : Theme.text))
                    if let time {
                        Text(time).font(Theme.mono(10)).foregroundStyle(mine ? Color.black.opacity(0.55) : Theme.dim)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(mine ? Theme.amber : Theme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if !mine { Spacer(minLength: 56) }
        }
    }
}

/// Group / Public switch above the message field.
struct ChannelPill: View {
    let title: String
    let selected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(Theme.mono(11, .bold)).tracking(1)
                .foregroundStyle(selected ? Color.black : Theme.dim)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? color : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? color : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// Message field with a round send button.
struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    var accent = Theme.amber
    var enabled = true
    let send: () -> Void
    private var canSend: Bool { enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line, lineWidth: 1))
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(canSend ? 1 : 0.3), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }
}

struct EmptyState<Art: View>: View {
    let title: String
    let text: String
    @ViewBuilder let art: () -> Art

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            art()
            HStack(spacing: 0) { Kicker(title, color: Theme.text); Cursor().font(Theme.mono(11, .semibold)) }
            Text(text).font(.subheadline).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - AI

struct AiView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var ai = LocalAi.shared
    @State private var draft = ""
    @State private var choosingModel = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { choosingModel = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                        Text(ai.selected.title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .buttonStyle(GhostButton())
                Spacer()
                Button("New") { ai.newConversation() }
                    .buttonStyle(GhostButton()).disabled(ai.busy || ai.conversation.isEmpty)
            }
            .padding(.horizontal, 12).padding(.top, 10)
            Text("Runs on this iPhone with no internet. It can be wrong: double-check anything important.")
                .font(.caption).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 8)

            if !ai.selectedReady {
                VStack {
                    Card {
                        Kicker("No AI model on this iPhone", color: Theme.alert)
                        Text("Download one while you still have internet. It stays on the phone and works offline afterwards.")
                            .font(.subheadline).foregroundStyle(Theme.text)
                        Button("Choose a model") { choosingModel = true }.buttonStyle(PrimaryButton())
                    }
                    Spacer()
                }
                .padding(12)
            } else if ai.conversation.isEmpty {
                EmptyState(title: "Ask anything",
                           text: "First aid, water, staying warm, what to pack. Or summarize what your group said.") {
                    Image(systemName: "sparkles").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.amber)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(ai.conversation.enumerated()), id: \.element.id) { i, t in
                                let mine = t.role == "user"
                                let newRun = i == 0 || ai.conversation[i - 1].role != t.role
                                Bubble(text: t.text, mine: mine, name: newRun && !mine ? "AI" : nil, isError: t.isError,
                                       busy: ai.busy && !mine && i == ai.conversation.count - 1)
                                    .padding(.top, newRun && i > 0 ? 10 : 0)
                                    .id(t.id)
                            }
                        }
                        .padding(12)
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

            VStack(alignment: .leading, spacing: 8) {
                Button { summarize() } label: { Label("Summarize group messages", systemImage: "text.alignleft") }
                    .buttonStyle(GhostButton())
                    .disabled(ai.busy || !ai.selectedReady || engine.messages.isEmpty)
                Composer(draft: $draft, placeholder: ai.busy ? "Thinking…" : "Ask the AI",
                         enabled: !ai.busy && ai.selectedReady) {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { draft = ""; ai.send(t) }
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
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

struct ModelPicker: View {
    @ObservedObject var ai: LocalAi
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("Models run entirely on this iPhone. Bigger ones answer better but slower.")
                        .font(.footnote).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(LocalAi.catalog) { m in row(m) }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("AI model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar { Button("Done") { dismiss() }.font(Theme.mono(15, .bold)) }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ m: AiModel) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Text(m.title).font(Theme.mono(16, .bold)).foregroundStyle(Theme.text)
                Spacer()
                if ai.selectedId == m.id && ai.states[m.id] == .ready { Chip("In use", Theme.live) }
            }
            Text(m.detail).font(.subheadline).foregroundStyle(Theme.text)
            Text("\(size) · \(m.license)").font(Theme.mono(11)).foregroundStyle(Theme.dim)
            switch ai.states[m.id] ?? .missing {
            case .ready:
                HStack {
                    if ai.selectedId != m.id { Button("Use this model") { ai.select(m) }.buttonStyle(GhostButton()) }
                    Spacer()
                    Button("Delete", role: .destructive) { ai.delete(m) }
                        .font(Theme.mono(12, .bold)).foregroundStyle(Theme.alert).disabled(ai.busy)
                }
            case .missing:
                Button("Download \(size)") { ai.download(m) }.buttonStyle(PrimaryButton()).disabled(ai.isDownloading)
            case .downloading(let p):
                Segments(progress: p)
                Text("Downloading \(Int(p * 100))%. Keep the app open.").font(Theme.mono(11)).foregroundStyle(Theme.amber)
            case .verifying:
                HStack(spacing: 0) { Kicker("Checking the download", color: Theme.amber); Cursor() }
            case .failed(let why):
                Text("Download failed: \(why)").font(.footnote).foregroundStyle(Theme.alert)
                Button("Try again") { ai.download(m) }.buttonStyle(GhostButton()).disabled(ai.isDownloading)
            }
        }
    }
}

/// Segmented console progress bar.
struct Segments: View {
    let progress: Double
    var count = 24
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Double(i) < progress * Double(count) ? Theme.amber : Theme.amber.opacity(0.15))
                    .frame(height: 10)
            }
        }
        .accessibilityElement().accessibilityLabel("\(Int(progress * 100)) percent")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    HStack {
                        Kicker("LoRa radio", color: Theme.amber)
                        Spacer()
                        Chip(engine.radioLinked ? "Linked" : "Not linked", engine.radioLinked ? Theme.live : Theme.dim)
                    }
                    Text(statusText).font(Theme.mono(14, .semibold)).foregroundStyle(Theme.text)
                    Button(searching ? "Search again" : "Search for radios") {
                        radios = []; searching = true
                        engine.lora.scan { id, name in
                            if !radios.contains(where: { $0.id == id }) { radios.append(Radio(id: id, name: name)) }
                        }
                    }
                    .buttonStyle(PrimaryButton())
                    if searching && radios.isEmpty {
                        HStack(spacing: 0) { Kicker("Looking for radios nearby", color: Theme.amber); Cursor() }
                        Text("Turn the radio on and keep it next to the phone.").font(.footnote).foregroundStyle(Theme.dim)
                    }
                    ForEach(radios) { r in
                        Button {
                            engine.lora.select(r.id)
                            note = "Connecting. If asked, enter the PIN shown on the radio."
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(Theme.amber)
                                Text(r.name).font(Theme.mono(14, .semibold)).foregroundStyle(Theme.text)
                                Spacer()
                                Text("CONNECT").font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
                            }
                            .padding(12)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(Theme.dim) }
                }
                Card {
                    Kicker("What it does")
                    Text("A Meshtastic LoRa radio pairs with this iPhone over Bluetooth and reaches other radios kilometers away: about 2–10 km in a city, more in open country or from high places. Every radio also relays for the others.")
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Kicker("Limits")
                    Text("Short messages only (about 160 characters), one every 20 seconds, and only from the last 30 minutes.")
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Kicker("You need")
                    Text("A Meshtastic radio set to the EU_868 region, for example a Heltec V3.")
                        .font(.subheadline).foregroundStyle(Theme.text)
                }
            }
            .padding(12)
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
            Card {
                Kicker("Debug build only", color: Theme.alert)
                Text("Connects over TCP to the Android app's LAN test listener, to test chat, relaying, and encryption between the two apps. This does NOT test Bluetooth or Apple peer-to-peer.")
                    .font(.subheadline).foregroundStyle(Theme.text)
                Text("From the iOS Simulator, 127.0.0.1:7777 reaches an Android emulator after running on the computer:\nadb -s <emulator> forward tcp:7777 tcp:7777")
                    .font(Theme.mono(11)).foregroundStyle(Theme.dim)
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
            .padding(12)
        }
    }
}
#endif
