import SwiftUI

/// DarkProof's look, taken from the logo: white on pure black (black pixels are off on OLED screens, which saves
/// battery), soft charcoal cards, white capsule buttons. Color only means something: green = safe or connected,
/// red = help. The logo's outline (cut top-left corner, round right side) is the one signature shape.
enum Theme {
    static let bg = Color.black
    static let card = Color(white: 0.075)   // cards and lists
    static let tile = Color(white: 0.13)    // inputs, other people's bubbles, secondary buttons
    static let line = Color(white: 0.17)    // dividers
    static let text = Color.white
    static let dim = Color(white: 0.64)     // secondary text: 7:1 on black, 5.8:1 on tiles
    static let faint = Color(white: 0.54)   // hints and placeholders: still at least 4.5:1 on black, cards and tiles
    static let decor = Color(white: 0.38)   // only for shapes that carry no information (chevrons, empty states)
    static let safe = Color(red: 0.2, green: 0.84, blue: 0.29)
    static let help = Color(red: 1.0, green: 0.27, blue: 0.23)

    /// Animations stay off with Reduce Motion or Low Power Mode: in a blackout the battery matters more.
    static var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// A font size that follows the user's text size (Settings > Display > Text Size), like the system text styles,
    /// with a ceiling so screens keep their layout: body text grows up to about 1.7×, titles less.
    static func scaled(_ size: CGFloat, _ dts: DynamicTypeSize) -> CGFloat {
        let s = UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: UITraitCollection(preferredContentSizeCategory: category(dts)))
        let cap: CGFloat = size >= 40 ? 1.15 : size >= 24 ? 1.35 : 1.7
        return max(size * 0.8, min(s, size * cap)).rounded()
    }

    private static func category(_ d: DynamicTypeSize) -> UIContentSizeCategory {
        switch d {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// `.scaledFont(17, .semibold)`: the system font at a size that follows Dynamic Type (Theme.scaled).
struct ScaledFont: ViewModifier {
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    @Environment(\.dynamicTypeSize) private var dts
    func body(content: Content) -> some View { content.font(.system(size: Theme.scaled(size, dts), weight: weight, design: design)) }
}

extension View {
    func scaledFont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

/// Opens DarkProof's page in the iPhone Settings app (permissions, notifications).
struct OpenSettingsButton: View {
    var title = "Open Settings"
    var body: some View {
        Button(title) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            .buttonStyle(GhostButton())
    }
}

/// The logo's silhouette: cut top-left corner, round right side, near-square bottom-left.
struct VaultShape: Shape {
    var cut: CGFloat = 42, radius: CGFloat = 46, small: CGFloat = 8
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + cut, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: small)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cut))
        p.closeSubpath()
        return p
    }
}

/// The DarkProof mark (white logo on transparent, from brand/darkproof-logo.png).
struct Logo: View {
    var size: CGFloat
    var body: some View {
        Image("Logo").resizable().renderingMode(.template).scaledToFit()
            .frame(width: size, height: size).foregroundStyle(Theme.text).accessibilityLabel("DarkProof")
    }
}

/// Small section label above a field or group, in sentence case.
struct Kicker: View {
    let text: String
    var color = Theme.dim
    init(_ text: String, color: Color = Theme.dim) { self.text = text; self.color = color }
    var body: some View { Text(text).scaledFont(14, .semibold).foregroundStyle(color) }
}

/// Section title with an optional action on the right, e.g. "Your people · See all".
struct SectionTitle: View {
    let title: String
    var action: String? = nil
    var tap: () -> Void = {}
    var body: some View {
        HStack {
            Text(title).scaledFont(20, .bold).foregroundStyle(Theme.text)
            Spacer()
            if let action {
                Button(action, action: tap).scaledFont(15, .semibold).foregroundStyle(Theme.dim)
            }
        }
    }
}

/// Filled capsule tag, e.g. "Nearby" or "In use".
struct Chip: View {
    let text: String
    var color = Theme.dim
    init(_ text: String, _ color: Color = Theme.dim) { self.text = text; self.color = color }
    var body: some View {
        Text(text).scaledFont(13, .semibold).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color == Theme.dim ? Theme.tile : color.opacity(0.14), in: Capsule())
    }
}

/// A soft charcoal card, no border.
struct Card<Content: View>: View {
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The one main action on a screen: full-width white capsule, black text.
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, primary: true) }
    fileprivate struct Styled: View {
        let configuration: Configuration
        let primary: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .scaledFont(17, .semibold)
                .foregroundStyle(primary ? Color.black : Theme.text)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(primary ? Color.white : Theme.tile, in: Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// A second full-width action: dark capsule, white text.
struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PrimaryButton.Styled(configuration: configuration, primary: false) }
}

/// A small inline action, e.g. "Switch" in a row: compact dark capsule.
struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .scaledFont(15, .semibold).foregroundStyle(Theme.text)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Theme.tile, in: Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
        }
    }
}

/// Round icon button, e.g. settings in a header.
struct RoundIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).scaledFont(17, .semibold).foregroundStyle(Theme.text)
            .frame(width: 42, height: 42).background(Circle().fill(Theme.tile))
    }
}

/// Big title with a line under it, at the top of a tab.
struct ScreenTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledFont(32, .heavy).tracking(-0.5).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle).scaledFont(15, .medium).foregroundStyle(Theme.dim)
        }
    }
}

/// Thin white progress bar.
struct ProgressLine: View {
    let progress: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.tile)
                Capsule().fill(Theme.text).frame(width: g.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: 8)
        .accessibilityElement().accessibilityLabel("\(Int(progress * 100)) percent")
    }
}

/// Two-way switch in a capsule, e.g. List | Map.
struct PillSwitch: View {
    let left: String
    let right: String
    @Binding var isRight: Bool

    var body: some View {
        HStack(spacing: 4) {
            segment(left, on: !isRight) { isRight = false }
            segment(right, on: isRight) { isRight = true }
        }
        .padding(4).background(Capsule().fill(Theme.tile))
        .animation(.easeOut(duration: 0.15), value: isRight)
    }

    private func segment(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).scaledFont(15, .semibold).lineLimit(1)
                .foregroundStyle(on ? Color.black : Theme.dim)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Capsule().fill(on ? Color.white : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
