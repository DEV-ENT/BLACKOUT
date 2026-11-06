import AppIntents
import BlackoutCore

/// "I'm safe" and "I need help" for Siri, Spotlight, the Action button and the Shortcuts app. They run without opening
/// DarkProof: the mesh starts if it isn't running and the check-in is queued like one sent from the app, then goes out
/// over whatever link is in reach. (A Control Center or Lock Screen control would need a widget extension: not added.)
struct SafeIntent: AppIntent {
    static var title: LocalizedStringResource = "I'm safe"
    static var description = IntentDescription("Tells your DarkProof group you're safe, with your battery level and, if you share it, your position.")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await CheckInShortcut.send(.safe)))
    }
}

struct HelpIntent: AppIntent {
    static var title: LocalizedStringResource = "I need help"
    static var description = IntentDescription("Tells your DarkProof group you need help, with your battery level and, if you share it, your position.")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await CheckInShortcut.send(.help)))
    }
}

enum CheckInShortcut {
    /// Queues the check-in in the group on screen and says what happened. Main thread.
    @MainActor static func send(_ c: CheckIn) async -> String {
        Mesh.shared.startIfSetUp()
        guard let e = Mesh.shared.engine else { return "Open DarkProof and join a group first." }
        let group = UserDefaults.standard.string(forKey: "groupName") ?? "your group"
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if e.checkInSending != nil { return done.resume() } // one is on its way already
            e.checkIn(c) { done.resume() }
        }
        let what = c == .safe ? "“I'm safe”" : "“I need help”"
        return e.reach == .none ? "\(what) for \(group) waits on this iPhone and goes out as soon as a phone is in range."
                                : "Sent \(what) to \(group)."
    }
}

struct DarkProofShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SafeIntent(), phrases: ["I'm safe in \(.applicationName)", "Tell \(.applicationName) I'm safe",
                                                    "\(.applicationName) I'm safe"],
                    shortTitle: "I'm safe", systemImageName: "checkmark.shield.fill")
        AppShortcut(intent: HelpIntent(), phrases: ["I need help in \(.applicationName)", "Tell \(.applicationName) I need help",
                                                    "\(.applicationName) I need help"],
                    shortTitle: "I need help", systemImageName: "sos")
    }
}
