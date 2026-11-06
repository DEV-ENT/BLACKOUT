import SwiftUI
import AppIntents
import BlackoutCore

/// "Get ready" on Home: what to do while there is still power and internet. Each step opens the right screen; the
/// card can be hidden and hides itself once everything is done.
struct GetReadyCard: View {
    @ObservedObject var engine: Engine
    let hasPeople: Bool
    @ObservedObject private var map = OfflineMap.shared
    @ObservedObject private var ai = LocalAi.shared
    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var nav = Nav.shared
    @AppStorage("didInvite") private var didInvite = false
    @AppStorage("didShortcut") private var didShortcut = false
    @AppStorage("didPractice") private var didPractice = false
    @AppStorage("hideGetReady") private var hidden = false

    private struct Step: Identifiable { let id: String; let icon: String; let title: String; let note: String?; let done: Bool; let open: () -> Void }

    private var steps: [Step] {
        let mapDone: Bool = { if case .ready = map.state { return true }; return false }()
        let aiDone = ai.states.values.contains(.ready)
        let notes: Bool = [.authorized, .provisional, .ephemeral].contains(notifier.status)
        return [
            Step(id: "invite", icon: "qrcode", title: "Invite your people", note: nil, done: didInvite || hasPeople) { nav.sheet = .invite },
            Step(id: "map", icon: "map.fill", title: "Save the map of your area", note: nil, done: mapDone) { nav.placesMap = true; nav.tab = .places },
            Step(id: "notify", icon: "bell.fill", title: "Turn on notifications", note: nil, done: notes) {
                if notifier.status == .notDetermined { notifier.requestPermission() }
                else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            },
            Step(id: "shortcut", icon: "checkmark.shield.fill", title: "Add the “I'm safe” shortcut", note: nil, done: didShortcut) { nav.sheet = .shortcut },
            Step(id: "practice", icon: "graduationcap.fill", title: "Try a practice run", note: "Nothing is sent", done: didPractice) { nav.sheet = .practice },
            Step(id: "ai", icon: "sparkles", title: "Download the offline assistant", note: "Optional. 1.4–4.6 GB: use Wi-Fi", done: aiDone) {
                nav.tab = .ask; nav.sheet = .models
            },
        ]
    }

    var body: some View {
        let s = steps, done = s.filter(\.done).count
        if !hidden && done < s.count {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get ready").scaledFont(20, .bold).foregroundStyle(Theme.text)
                        Text("While there is power and internet · \(done) of \(s.count) done").scaledFont(14).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Button("Hide") { withAnimation { hidden = true } }.buttonStyle(GhostButton())
                        .accessibilityLabel("Hide the Get ready list")
                }
                ProgressLine(progress: Double(done) / Double(s.count))
                VStack(spacing: 0) {
                    ForEach(s) { step in
                        Button(action: step.open) {
                            HStack(spacing: 12) {
                                Image(systemName: step.done ? "checkmark.circle.fill" : step.icon)
                                    .scaledFont(17, .semibold).foregroundStyle(step.done ? Theme.safe : Theme.text).frame(width: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(step.title).scaledFont(16, .semibold).foregroundStyle(step.done ? Theme.dim : Theme.text)
                                        .strikethrough(step.done, color: Theme.dim)
                                    if let n = step.note, !step.done { Text(n).scaledFont(13).foregroundStyle(Theme.dim) }
                                }
                                Spacer()
                                if !step.done { Image(systemName: "chevron.right").scaledFont(13, .bold).foregroundStyle(Theme.decor) }
                            }
                            .padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(step.done)
                        .accessibilityLabel(step.title + (step.done ? ", done" : ""))
                    }
                }
            }
            .padding(20)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onAppear { notifier.refresh() }
        }
    }
}

/// How to send "I'm safe" without opening DarkProof: Siri, the Action button, the Home Screen.
struct ShortcutSheet: View {
    @AppStorage("didShortcut") private var didShortcut = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetPage(title: "Shortcut") {
            Text("Check in without opening DarkProof").scaledFont(26, .heavy).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("“I'm safe” and “I need help” work from Siri, Spotlight, the Action button and the Shortcuts app. They go to the group on screen, like the buttons in the app.")
                .scaledFont(15).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            SiriTipView(intent: SafeIntent()).siriTipViewStyle(.dark)
            Card {
                row("mic.fill", "Siri", "Say “I'm safe in DarkProof” or “I need help in DarkProof”.")
                row("button.horizontal.top.press.fill", "Action button", "iPhone 15 Pro and newer: Settings > Action Button > Shortcut > DarkProof.")
                row("square.grid.2x2.fill", "Home Screen", "In the Shortcuts app, hold “I'm safe” and choose Add to Home Screen.")
            }
            // Not ShortcutsLink: it shows the build's bundle name ("Blackout"), not DarkProof.
            Button { didShortcut = true; if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) } } label: {
                Label("Open the Shortcuts app", systemImage: "square.2.layers.3d.fill")
            }
            .buttonStyle(SecondaryButton())
            Button("Done") { didShortcut = true; dismiss() }.buttonStyle(PrimaryButton())
        }
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.text).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(16, .semibold).foregroundStyle(Theme.text)
                Text(text).scaledFont(14).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
