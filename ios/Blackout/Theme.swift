import SwiftUI

/// Blackout's look: a field-radio console on pure black (black pixels are off on OLED screens, which saves battery).
/// Amber is kept for actions and your own messages, green for links that are up, cyan for the Public channel.
enum Theme {
    static let bg = Color.black
    static let panel = Color(white: 0.07)   // cards
    static let raised = Color(white: 0.12)  // other people's bubbles, inputs
    static let line = Color(white: 0.2)     // hairline borders
    static let text = Color(white: 0.95)
    static let dim = Color(white: 0.56)
    static let amber = Color(red: 1.0, green: 0.65, blue: 0.1)
    static let live = Color(red: 0.3, green: 0.88, blue: 0.5)
    static let open = Color(red: 0.25, green: 0.75, blue: 0.98)
    static let alert = Color(red: 1.0, green: 0.4, blue: 0.32)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Animations stay off with Reduce Motion or Low Power Mode: in a blackout the battery matters more.
    static var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

/// Small uppercase console label.
struct Kicker: View {
    let text: String
    var color = Theme.dim
    init(_ text: String, color: Color = Theme.dim) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(Theme.mono(11, .semibold)).tracking(1.6).foregroundStyle(color)
    }
}

/// Outlined capsule tag, e.g. PUBLIC or BT 2.
struct Chip: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(Theme.mono(10, .bold)).tracking(0.8).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
    }
}

/// A console panel: dark card with a hairline border.
struct Card<Content: View>: View {
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

/// The one loud button on a screen: solid amber, black text.
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(Theme.mono(15, .bold)).tracking(1.2).textCase(.uppercase)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.amber.opacity(enabled ? 1 : 0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// Secondary action: amber text on an outline.
struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(Theme.mono(12, .bold)).tracking(1).textCase(.uppercase)
                .foregroundStyle(Theme.amber.opacity(enabled ? 1 : 0.35))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(Capsule().stroke(Theme.amber.opacity(enabled ? 0.5 : 0.2), lineWidth: 1))
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}

/// Blinking console cursor.
struct Cursor: View {
    var color = Theme.amber
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion || Theme.lowPower {
            Text("_").foregroundStyle(color)
        } else {
            TimelineView(.periodic(from: .now, by: 0.55)) { t in
                Text("_").foregroundStyle(color)
                    .opacity(Int(t.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0 ? 1 : 0)
            }
        }
    }
}

/// Radar with one green blip per linked phone and an antenna when a LoRa radio is linked. You are the center.
struct Radar: View {
    var phones: Int
    var radio = false
    var sweeping = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            ZStack {
                ForEach(1...3, id: \.self) { i in
                    Circle().stroke(Theme.amber.opacity(0.12 + 0.1 * Double(i)), lineWidth: 1)
                        .frame(width: 2 * r * CGFloat(i) / 3, height: 2 * r * CGFloat(i) / 3)
                }
                Path { p in
                    p.move(to: CGPoint(x: r, y: 0)); p.addLine(to: CGPoint(x: r, y: 2 * r))
                    p.move(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: 2 * r, y: r))
                }
                .stroke(Theme.amber.opacity(0.15), lineWidth: 1)
                if sweeping && !reduceMotion && !Theme.lowPower {
                    Circle()
                        .fill(AngularGradient(gradient: Gradient(stops: [
                            .init(color: .clear, location: 0), .init(color: .clear, location: 0.7),
                            .init(color: Theme.amber.opacity(0.5), location: 1)]), center: .center))
                        .rotationEffect(.degrees(angle))
                        .onAppear { withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { angle = 360 } }
                }
                ForEach(0..<min(phones, 12), id: \.self) { i in
                    Circle().fill(Theme.live).frame(width: max(5, r * 0.14), height: max(5, r * 0.14))
                        .shadow(color: Theme.live.opacity(0.8), radius: 4)
                        .offset(Self.blip(i, r))
                }
                if radio {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: max(9, r * 0.32), weight: .bold)).foregroundStyle(Theme.amber)
                        .offset(x: r * 0.55, y: -r * 0.55)
                }
                Circle().fill(Theme.amber).frame(width: max(5, r * 0.12), height: max(5, r * 0.12))
            }
            .frame(width: 2 * r, height: 2 * r)
            .clipShape(Circle())
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(phones == 0 ? "No phones linked" : "\(phones) phones linked")
    }

    /// Spreads blips around the center with the golden angle, at a stable spot per index.
    private static func blip(_ i: Int, _ r: CGFloat) -> CGSize {
        let a = Double(i) * 2.39996 - 0.9
        let d = r * (0.42 + 0.42 * CGFloat((i * 7) % 5) / 4)
        return CGSize(width: cos(a) * d, height: sin(a) * d)
    }
}
