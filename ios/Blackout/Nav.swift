import SwiftUI
import CryptoKit
import BlackoutCore

/// Where the app is: the tab, the chat channel, sheets opened from far away (an alert, the Get ready list), short
/// confirmations ("toasts") and in-app alerts. Main thread only.
final class Nav: ObservableObject {
    static let shared = Nav()
    enum Tab: Int { case home, chat, places, people, ask }

    @Published var tab = Tab.home
    @Published var chatEveryone = false
    @Published var placesMap = false
    @Published var sheet: MainView.Sheet?
    @Published private(set) var toast: String?
    @Published var banner: Banner?
    /// A group was just created in setup: open its invite once the permission questions are answered.
    var inviteAfterSetup = false
    private var toastTimer: DispatchWorkItem?
    private var bannerTimer: DispatchWorkItem?

    /// A short confirmation at the bottom of the screen, e.g. "Reported and hidden on this phone".
    func toast(_ text: String) {
        toastTimer?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        let t = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil } }
        toastTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: t)
    }

    /// An alert inside the app (DarkProof is on screen, so iOS shows none): someone needs help, someone asks if you
    /// are safe, or another saved group wrote. Comes with a haptic; stays longer for help.
    func show(_ b: Banner) {
        if let shown = banner, shown.kind.rank > b.kind.rank { return } // a help alert stays until it is closed or times out
        bannerTimer?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { banner = b }
        switch b.kind {
        case .help, .ask: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .message: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        let t = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.2)) { if self?.banner?.id == b.id { self?.banner = nil } } }
        bannerTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + (b.kind == .message ? 5 : 12), execute: t)
    }

    /// Shows a group's chat or people: switches group first if needed (`code` nil = stay).
    func open(group code: String?, tab: Tab, everyone: Bool = false) {
        if let code, !code.isEmpty, let e = Mesh.shared.engine, code != UserDefaults.standard.string(forKey: "code") {
            let name = SavedGroups.all().first { $0.code == code }?.name ?? "Group"
            SavedGroups.switchTo(groupName: name, code: code, engine: e)
        }
        sheet = nil
        if tab == .chat { chatEveryone = everyone }
        self.tab = tab
    }
}

/// An alert shown inside the app.
struct Banner: Identifiable, Equatable {
    enum Kind {
        case help, ask, message
        var rank: Int { self == .help ? 2 : self == .ask ? 1 : 0 }
    }
    let id: String          // message id
    let kind: Kind
    let title: String
    let body: String
    let group: String       // group code of the message ("" for Everyone)
    let tab: Nav.Tab
}

/// A stable, short, non-secret label for a group (for notification data, so codes never sit in the alert database).
enum GroupTag {
    static func of(_ code: String) -> String {
        SHA256.hash(data: Data(("darkproof-tag|" + code).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The saved group with this tag, if any.
    static func code(for tag: String) -> String? {
        let d = UserDefaults.standard
        let all = SavedGroups.all().map(\.code) + [d.string(forKey: "code") ?? ""]
        return all.first { !$0.isEmpty && of($0) == tag }
    }
}

/// What has been read: the newest message time seen per group code (and "everyone" for the Everyone channel), saved
/// on the phone. Unread = messages from others after that. Main thread.
final class Unread: ObservableObject {
    static let shared = Unread()
    static let everyone = "everyone"
    private let key = "lastRead"
    @Published private(set) var lastRead: [String: Int64]

    init() {
        let d = UserDefaults.standard
        if let saved = d.dictionary(forKey: key) as? [String: Int64] {
            lastRead = saved
        } else { // first launch with this feature: everything so far counts as read
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var r = [Self.everyone: now]
            for g in SavedGroups.all() { r[g.code] = now }
            if let c = d.string(forKey: "code"), !c.isEmpty { r[c] = now }
            lastRead = r
            d.set(r, forKey: key)
        }
    }

    /// Everything up to `ts` in this channel was seen.
    func markRead(_ channel: String, upTo ts: Int64) {
        guard ts > lastRead[channel] ?? 0 else { return }
        lastRead[channel] = ts
        UserDefaults.standard.set(lastRead, forKey: key)
        updateAppBadge()
    }

    /// Messages from others in a group (by code) or in Everyone that came after the last one seen there.
    func count(_ channel: String, in all: [Message], me: String) -> Int {
        let since = lastRead[channel] ?? 0
        return all.reduce(0) { n, m in
            let inChannel = channel == Self.everyone ? m.isPublic : (!m.isPublic && m.group == channel)
            return n + (inChannel && m.sender != me && m.ts > since && Place.of(m.text) == nil ? 1 : 0)
        }
    }

    /// The app icon shows how many group messages are unread, in every saved group (not Everyone).
    func updateAppBadge() {
        guard let e = Mesh.shared.engine else { return }
        let codes = Set(e.allMessages.compactMap { $0.isPublic ? nil : $0.group })
        let n = codes.reduce(0) { $0 + count($1, in: e.allMessages, me: e.deviceId) }
        UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
    }
}

/// Unsent text per chat channel (a group's code, or "everyone"), so a draft for the group never goes to Everyone.
final class Drafts: ObservableObject {
    static let shared = Drafts()
    @Published var text: [String: String] = [:]
    func binding(_ channel: String) -> Binding<String> {
        Binding(get: { self.text[channel] ?? "" }, set: { self.text[channel] = $0 })
    }
}

/// The in-app alert at the top and the toast at the bottom, over every tab.
struct Overlays: ViewModifier {
    @ObservedObject var nav = Nav.shared
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let b = nav.banner { BannerView(banner: b).padding(.horizontal, 12).padding(.top, 4).transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .modifier(ToastOverlay())
    }
}

/// A short confirmation at the bottom (Nav.toast).
struct ToastOverlay: ViewModifier {
    @ObservedObject var nav = Nav.shared
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let t = nav.toast {
                    Text(t).scaledFont(15, .semibold).foregroundStyle(Color.black).multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Color.white, in: Capsule())
                        .shadow(color: .black.opacity(0.6), radius: 16)
                        .padding(.bottom, 64).padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                        .onAppear { UIAccessibility.post(notification: .announcement, argument: t) }
                }
            }
    }
}

struct BannerView: View {
    let banner: Banner
    @ObservedObject private var nav = Nav.shared

    var body: some View {
        let tint: Color = banner.kind == .help ? Theme.help : banner.kind == .ask ? Theme.text : Theme.dim
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: banner.kind == .help ? "sos" : banner.kind == .ask ? "questionmark.bubble.fill" : "bubble.left.fill")
                    .scaledFont(17, .bold).foregroundStyle(tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).scaledFont(16, .bold).foregroundStyle(Theme.text)
                    Text(banner.body).scaledFont(14).foregroundStyle(Theme.dim).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button { withAnimation { nav.banner = nil } } label: {
                    Image(systemName: "xmark").scaledFont(13, .bold).foregroundStyle(Theme.dim).frame(width: 30, height: 30)
                }
                .accessibilityLabel("Close")
            }
            if banner.kind == .ask {
                HStack(spacing: 10) {
                    Button("I'm safe") { answer(.safe) }.buttonStyle(GhostButton())
                    Button("I need help") { nav.banner = nil; nav.open(group: banner.group, tab: .home); nav.sheet = .help }
                        .buttonStyle(GhostButton())
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(tint.opacity(0.6), lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { nav.banner = nil; nav.open(group: banner.group, tab: banner.tab) }
        .accessibilityElement(children: .contain)
    }

    private func answer(_ c: CheckIn) {
        nav.banner = nil
        guard let e = Mesh.shared.engine else { return }
        e.checkIn(c, group: banner.group.isEmpty ? nil : banner.group) { nav.toast(e.queuedToast("“I'm safe”")) }
    }
}
