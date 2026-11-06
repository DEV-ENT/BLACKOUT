import SwiftUI
import BlackoutCore

// MARK: - Ask (offline AI)

struct AiView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var ai = LocalAi.shared
    @State private var draft = ""
    @State private var choosingModel = false
    @State private var confirmNew = false
    @AppStorage("groupName") private var groupName = "My group"

    private var groupMessages: [Message] { engine.messages.filter { !$0.isPublic } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ScreenTitle(title: "Ask", subtitle: "Offline assistant on this iPhone")
                    Spacer()
                    Button("New") { confirmNew = true }.buttonStyle(GhostButton())
                        .disabled(ai.busy || ai.conversation.isEmpty)
                        .accessibilityLabel("New conversation")
                }
                Button { choosingModel = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                        Text(ai.selected.title).lineLimit(1)
                        Image(systemName: "chevron.down").scaledFont(11, .bold)
                    }
                }
                .buttonStyle(GhostButton())
                .accessibilityLabel("AI model: \(ai.selected.title)")
                Text("It works with no internet and can be wrong. Double-check anything important.")
                    .scaledFont(13).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)

            if !ai.selectedReady {
                ScrollView {
                    Card {
                        Text("No AI model on this iPhone").scaledFont(20, .bold).foregroundStyle(Theme.text)
                        Text("Download one while you still have internet, ideally on Wi-Fi: they are big (1.4–4.6 GB). It stays on the phone and works offline afterwards.")
                            .scaledFont(16).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                        Button("Choose a model") { choosingModel = true }.buttonStyle(PrimaryButton())
                    }
                    .padding(20)
                }
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
                Button { summarize() } label: { Label("Summarize \(groupName)", systemImage: "text.alignleft") }
                    .buttonStyle(GhostButton())
                    .disabled(ai.busy || !ai.selectedReady || groupMessages.isEmpty)
                Composer(draft: $draft, placeholder: ai.busy ? "Thinking…" : "Ask a question",
                         enabled: !ai.busy && ai.selectedReady) {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        draft = ""
                        ai.send(t, situation: Situation.text(engine: engine, groupName: groupName, me: LocationService.shared.location?.spot))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $choosingModel) { ModelPicker(ai: ai) }
        .confirmationDialog("Start a new conversation?", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("New conversation", role: .destructive) { ai.newConversation() }
            Button("Keep this one", role: .cancel) {}
        } message: {
            Text("This conversation is deleted from the phone.")
        }
    }

    /// The group's recent messages (not Everyone), kept within what the model can read at once (about 4 characters
    /// per token).
    private func summarize() {
        var h = groupMessages.suffix(40).map {
            "\(ChatTime.stamp($0.ts)) \($0.name): \($0.text.prefix(300))"
        }.joined(separator: "\n")
        h = String(h.suffix(Int(ai.selected.context) * 2))
        if !h.isEmpty {
            ai.send("Summarize these emergency messages from my group: who is safe, who is asking for help, and what is missing. Do not make anything up.\n\n\(h)")
        }
    }
}

struct ModelPicker: View {
    @ObservedObject var ai: LocalAi
    @State private var confirmDownload: AiModel?
    @State private var confirmDelete: AiModel?

    var body: some View {
        SheetPage(title: "AI model") {
            Text("Models run entirely on this iPhone. Bigger ones answer better but slower. This iPhone has \(LocalAi.memoryGB) GB of memory: only models that fit are shown.")
                .scaledFont(15).foregroundStyle(Theme.dim)
            if ai.onMobileData {
                Label("You're on mobile data. Models are big: use Wi-Fi if you can.", systemImage: "antenna.radiowaves.left.and.right")
                    .scaledFont(15, .semibold).foregroundStyle(Theme.help)
            }
            ForEach(LocalAi.catalog) { m in row(m) }
        }
        .confirmationDialog(confirmDownload.map { "Download \(Self.size($0))?" } ?? "", isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } }),
                            titleVisibility: .visible, presenting: confirmDownload) { m in
            Button("Download \(Self.size(m))") { ai.download(m) }
            Button("Not now", role: .cancel) {}
        } message: { m in
            Text((ai.onMobileData ? "You're on mobile data: this uses \(Self.size(m)) of your plan. " : "Use Wi-Fi if you can. ")
                 + "Keep DarkProof open until it finishes: the screen stays on meanwhile.")
        }
        .confirmationDialog(confirmDelete.map { "Delete \($0.title)?" } ?? "", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { m in
            Button("Delete", role: .destructive) { ai.delete(m) }
            Button("Keep", role: .cancel) {}
        } message: { m in
            Text("It frees \(Self.size(m)). To use it again you need to download it again, with internet.")
        }
    }

    static func size(_ m: AiModel) -> String { ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file) }

    private func row(_ m: AiModel) -> some View {
        let size = Self.size(m)
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Text(m.title).scaledFont(18, .bold).foregroundStyle(Theme.text)
                Spacer()
                if ai.selectedId == m.id && ai.states[m.id] == .ready { Chip("In use", Theme.safe) }
            }
            Text(m.detail).scaledFont(15).foregroundStyle(Theme.text)
            switch ai.speed(m) {
            case .measured(let s):
                Label("On this iPhone: about \(s) s per answer", systemImage: "timer").scaledFont(14, .semibold).foregroundStyle(Theme.text)
            case .estimated(let r):
                Label("On this iPhone: about \(r.lowerBound)–\(r.upperBound) s per answer (estimate until you use it)", systemImage: "timer")
                    .scaledFont(14).foregroundStyle(Theme.dim)
            case .unknown:
                Label("Speed on this iPhone shows after the first answers", systemImage: "timer").scaledFont(14).foregroundStyle(Theme.dim)
            }
            Text("\(size) · \(m.license)").scaledFont(13).foregroundStyle(Theme.dim)
            switch ai.states[m.id] ?? .missing {
            case .ready:
                HStack {
                    if ai.selectedId != m.id { Button("Use this model") { ai.select(m) }.buttonStyle(GhostButton()) }
                    Spacer()
                    Button("Delete", role: .destructive) { confirmDelete = m }
                        .scaledFont(15, .semibold).foregroundStyle(Theme.help).disabled(ai.busy)
                }
            case .missing:
                Button("Download \(size)") { confirmDownload = m }.buttonStyle(PrimaryButton()).disabled(ai.isDownloading)
            case .downloading(let p):
                ProgressLine(progress: p)
                HStack {
                    Text("Downloading \(Int(p * 100))%. Keep DarkProof open.").scaledFont(13).foregroundStyle(Theme.dim)
                    Spacer()
                    Button("Cancel") { ai.cancelDownload(m) }.buttonStyle(GhostButton())
                }
            case .paused(let p):
                ProgressLine(progress: p)
                HStack {
                    Text("Stopped at \(Int(p * 100))%.").scaledFont(13).foregroundStyle(Theme.dim)
                    Spacer()
                    Button("Resume") { ai.download(m) }.buttonStyle(GhostButton()).disabled(ai.isDownloading)
                }
            case .verifying:
                Text("Checking the download…").scaledFont(13).foregroundStyle(Theme.dim)
            case .failed(let why):
                Text("Download stopped: \(why).").font(.footnote).foregroundStyle(Theme.help)
                Button(ai.canResume(m) ? "Resume" : "Try again") { ai.download(m) }.buttonStyle(GhostButton()).disabled(ai.isDownloading)
            }
        }
    }
}
