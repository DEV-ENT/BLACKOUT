import SwiftUI
import BlackoutCore

struct RootView: View {
    @AppStorage("name") private var name = ""
    @AppStorage("code") private var code = ""
    @State private var engine: Engine?

    var body: some View {
        if let engine {
            MainView(engine: engine)
        } else if code.isEmpty {
            SetupView { n, c in name = n; code = c; engine = Engine(name: n, code: c) }
        } else {
            Color.black.ignoresSafeArea().onAppear { engine = Engine(name: name, code: code) }
        }
    }
}

struct SetupView: View {
    let join: (String, String) -> Void
    @State private var name = ""
    @State private var code = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a long code: anyone who knows it can read the group's messages.")
            TextField("Your name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Group code (same for everyone)", text: $code)
                .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button {
                let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
                let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
                if n.isEmpty || c.count < 8 { invalid = true } else { join(n, c) }
            } label: { Text("Join").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .alert("Enter your name and a code of at least 8 characters", isPresented: $invalid) { Button("OK", role: .cancel) {} }
    }
}

struct MainView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(engine.statusLines, id: \.self) { Text($0).font(.footnote).foregroundStyle(.green) }
                .padding(.horizontal)
            TabView {
                ChatView(engine: engine).tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                AiView(engine: engine).tabItem { Label("AI", systemImage: "sparkles") }
                RadioView(engine: engine).tabItem { Label("Radio", systemImage: "antenna.radiowaves.left.and.right") }
                #if DEBUG
                LanTestView(engine: engine).tabItem { Label("LAN test", systemImage: "network") }
                #endif
            }
        }
    }
}

struct ChatView: View {
    @ObservedObject var engine: Engine
    @State private var draft = ""
    @State private var tooLong = false
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(engine.messages, id: \.id) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Self.time.string(from: Date(timeIntervalSince1970: Double(m.ts) / 1000)))  \(m.sender == engine.deviceId ? "You" : m.name)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text(m.text).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: engine.messages.count) { _ in
                    if let last = engine.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                TextField("Message", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Send") {
                    let t = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
                    if !t.isEmpty {
                        draft = ""
                        if !engine.send(t) && engine.lora.connected { tooLong = true }
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .alert("Too long for LoRa: it will travel only over Bluetooth/Wi-Fi", isPresented: $tooLong) { Button("OK", role: .cancel) {} }
    }
}

struct AiView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var ai = LocalAi.shared
    @State private var draft = ""
    @State private var choosingModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { choosingModel = true } label: {
                    Label(ai.selected.title + (ai.selectedReady ? "" : " (not installed)"), systemImage: "cpu")
                }
                Spacer()
                Button("New conversation") { ai.newConversation() }.disabled(ai.busy || ai.conversation.isEmpty)
            }
            .font(.footnote)
            if !ai.selectedReady {
                Text("No AI model on this iPhone yet. Tap the model name above to download one while internet is available.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(ai.conversation) { t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.role == "user" ? "You" : "AI").font(.subheadline).foregroundStyle(.secondary)
                                Text(t.text).foregroundStyle(t.isError ? .orange : .primary).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(t.id)
                        }
                    }
                }
                .onChange(of: ai.conversation.last?.text) { _ in
                    if let last = ai.conversation.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                TextField("Ask the AI", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Send") {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { draft = ""; ai.send(t) }
                }
                .buttonStyle(.bordered)
                .disabled(ai.busy)
            }
            Button("Summarize group messages") {
                // Recent group messages, kept within what the model can read at once (about 4 characters per token).
                var h = engine.messages.suffix(40).map {
                    "\(ChatView.time.string(from: Date(timeIntervalSince1970: Double($0.ts) / 1000))) \($0.name): \($0.text.prefix(300))"
                }.joined(separator: "\n")
                h = String(h.suffix(Int(ai.selected.context) * 2))
                if !h.isEmpty {
                    ai.send("Summarize these emergency messages from my group: who is safe, who is asking for help, and what is missing. Do not make anything up.\n\n\(h)")
                }
            }
            .font(.footnote)
            .disabled(ai.busy || engine.messages.isEmpty)
        }
        .padding()
        .sheet(isPresented: $choosingModel) { ModelPicker(ai: ai) }
    }
}

struct ModelPicker: View {
    @ObservedObject var ai: LocalAi
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(LocalAi.catalog) { m in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(m.title).font(.headline)
                        Spacer()
                        if ai.selectedId == m.id && ai.states[m.id] == .ready { Text("In use").font(.footnote).foregroundStyle(.green) }
                    }
                    Text(m.detail).font(.footnote)
                    Text("\(ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)) · \(m.license)")
                        .font(.caption).foregroundStyle(.secondary)
                    switch ai.states[m.id] ?? .missing {
                    case .ready:
                        HStack {
                            if ai.selectedId != m.id { Button("Use this model") { ai.select(m) }.buttonStyle(.borderless) }
                            Spacer()
                            Button("Delete", role: .destructive) { ai.delete(m) }.buttonStyle(.borderless).disabled(ai.busy)
                        }
                    case .missing:
                        Button("Download (\(ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)))") { ai.download(m) }
                            .buttonStyle(.borderless).disabled(ai.isDownloading)
                    case .downloading(let p):
                        ProgressView(value: p) { Text("Downloading… \(Int(p * 100))%. Keep the app open.").font(.footnote) }
                    case .verifying:
                        ProgressView { Text("Checking the download…").font(.footnote) }
                    case .failed(let why):
                        Text("Download failed: \(why)").font(.footnote).foregroundStyle(.orange)
                        Button("Try again") { ai.download(m) }.buttonStyle(.borderless).disabled(ai.isDownloading)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("AI model")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct RadioView: View {
    struct Radio: Identifiable { let id: UUID; let name: String }
    @ObservedObject var engine: Engine
    @State private var radios: [Radio] = []
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meshtastic radio with the EU_868 region already set. Turn it on near the phone.")
            Button("Search for LoRa radios") {
                radios = []
                engine.lora.scan { id, name in if !radios.contains(where: { $0.id == id }) { radios.append(Radio(id: id, name: name)) } }
            }
            .buttonStyle(.borderedProminent)
            ForEach(radios) { r in
                Button(r.name) {
                    engine.lora.select(r.id)
                    note = "Connecting: if asked, enter the PIN shown on the radio"
                }
                .buttonStyle(.bordered)
            }
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
            Text("LoRa carries only short messages (about 160 characters), one every 20 seconds, and only from the last 30 minutes.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}

#if DEBUG
/// Debug builds only: connects to the Android app's LAN test listener over TCP.
struct LanTestView: View {
    @ObservedObject var engine: Engine
    @State private var address = "127.0.0.1:7777"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DEBUG BUILD ONLY. Connects over TCP to the Android app's LAN test listener, to test chat, relaying, and encryption between the two apps. This does NOT test Bluetooth or Apple peer-to-peer.")
            Text("From the iOS Simulator, 127.0.0.1:7777 reaches an Android emulator after running on the computer:\nadb -s <emulator> forward tcp:7777 tcp:7777")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("host:port", text: $address)
                .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Connect") {
                let a = address.trimmingCharacters(in: .whitespaces)
                if let i = a.lastIndex(of: ":"), let port = UInt16(a[a.index(after: i)...]), i > a.startIndex {
                    engine.lan.connect(host: String(a[..<i]), port: port)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Stop LAN test") { engine.lan.stop() }.buttonStyle(.bordered)
            Spacer()
        }
        .padding()
    }
}
#endif
