import UIKit
import UserNotifications
import BlackoutCore

/// Local alerts for new group messages and check-ins, made on this phone (no push server). Only while DarkProof isn't
/// on screen, including when iOS relaunched it in the background for Bluetooth.
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    /// Tab to show after the user taps an alert (MainView reads and clears it).
    @Published var openTab: Int?

    private var pending: [Message] = [] // main thread
    private var task = UIBackgroundTaskIdentifier.invalid
    private let center = UNUserNotificationCenter.current()

    func setUp() {
        center.delegate = self
        refresh()
        #if DEBUG
        if CommandLine.arguments.contains("notifyTest") { // pretend messages arrive just after going to the background
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                var hold = UIBackgroundTaskIdentifier.invalid // like a Bluetooth wake-up: a few seconds to run
                hold = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(hold) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { UIApplication.shared.endBackgroundTask(hold) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    self.received(Message(id: "test-help-\(now)", ts: now, sender: "test-l", name: "Lucia",
                                          text: CheckIn.help.text(battery: 9)), groupName: "Family")
                    self.received(Message(id: "test-msg-\(now)", ts: now, sender: "test-m", name: "Marco",
                                          text: "At the school gym, the road is flooded"), groupName: "Family")
                }
            }
        }
        #endif
    }

    func refresh() {
        center.getNotificationSettings { s in DispatchQueue.main.async { self.status = s.authorizationStatus } }
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in self.refresh() }
    }

    /// A group message just arrived from someone else. Messages arriving within 2 seconds are posted together:
    /// catching up after being out of range can bring dozens at once. Main thread.
    func received(_ m: Message, groupName: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        pending.append(m)
        guard pending.count == 1 else { return }
        // Ask iOS for a few seconds so the batch is posted even if it would suspend the app meanwhile.
        task = UIApplication.shared.beginBackgroundTask(withName: "alerts") { [weak self] in self?.flush(groupName) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.flush(groupName) }
    }

    private func flush(_ groupName: String) {
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid } }
        let batch = pending
        pending = []
        guard !batch.isEmpty else { return }
        // Someone asking for help always gets their own alert.
        let help = batch.filter { CheckIn.of($0.text) == .help }
        for m in help {
            post(id: m.id, title: "\(m.name) needs help", body: "Open DarkProof to see where and to answer.",
                 tab: 3, urgent: true)
        }
        let rest = batch.filter { CheckIn.of($0.text) != .help }
        if rest.count <= 3 {
            for m in rest { post(id: m.id, title: m.name, body: Self.body(m), subtitle: groupName, tab: CheckIn.of(m.text) == nil ? 1 : 3) }
        } else if let last = rest.last {
            let names = Array(Set(rest.map(\.name))).sorted()
            let who = names.count <= 2 ? names.joined(separator: " and ") : "\(names[0]), \(names[1]) and \(names.count - 2) more"
            post(id: last.id, title: "\(rest.count) new messages in \(groupName)", body: "From \(who).", tab: 1)
        }
    }

    static func body(_ m: Message) -> String {
        if let c = CheckIn.of(m.text) {
            let battery = CheckIn.battery(in: m.text).map { ", battery \($0)%" } ?? ""
            return c == .safe ? "Is safe\(battery)." : "Needs help\(battery)."
        }
        if m.photo != nil { let c = Photo.caption(m.text); return c.isEmpty ? "📷 Photo" : "📷 \(c)" }
        return String(m.text.prefix(300))
    }

    private func post(id: String, title: String, body: String, subtitle: String? = nil, tab: Int, urgent: Bool = false) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let subtitle { c.subtitle = subtitle }
        c.sound = .default
        c.threadIdentifier = urgent ? "help" : "group"
        c.userInfo = ["tab": tab]
        if urgent { c.interruptionLevel = .active; c.relevanceScore = 1 }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// On screen, the app itself shows what arrived: no banner.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let tab = r.notification.request.content.userInfo["tab"] as? Int
        DispatchQueue.main.async { self.openTab = tab; done() }
    }
}
