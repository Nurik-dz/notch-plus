import SwiftUI

/// A slim rounded level bar with a soft glow at its tip (volume and brightness).
struct LevelBar: View {
    let level: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(color)
                    .frame(width: max(geo.size.height, geo.size.width * min(max(level, 0), 1)))
                    .shadow(color: color.opacity(0.55), radius: 3)
            }
        }
    }
}

// MARK: - Buttons

/// The decision buttons on the cards (Allow, Deny, Reply...): the same glass as the chips, a little taller.
/// Colour carries meaning: green allows, red denies or warns, the rest is plain glass.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case allow, danger, deny, quiet }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(12.5, .semibold))
            .foregroundStyle(kind == .deny ? Color(red: 1.0, green: 0.62, blue: 0.60) : Color.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .chipGlass(tint: tint, strength: kind == .deny ? 0.4 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }

    private var tint: Color? {
        switch kind {
        case .allow: Theme.green
        case .danger, .deny: Theme.red
        case .quiet: nil
        }
    }
}

/// The one button look for actions inside the island: a capsule of glass, 28 high. The main action of a row carries
/// a tint (`primary`), everything else is plain glass (`secondary`), so every row has one clear first choice.
/// The glass itself answers the pointer and the press; use it as the label of a plain Button or a Menu.
struct ChipLabel: View {
    enum Kind { case primary, secondary }
    let title: String
    var symbol: String?
    var menu = false                       // a chevron, for a button that opens a menu
    var kind: Kind = .secondary
    var tint: Color = Theme.violet

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            Text(title).font(Theme.label(11.5, .semibold)).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7) }
        }
        .foregroundStyle(kind == .primary ? Color.white : .white.opacity(0.88))
        .padding(.horizontal, 12).frame(height: 28)
        .chipGlass(tint: kind == .primary ? tint : nil)
    }
}

extension View {
    /// The surface every button in the island shares: a capsule of glass. With a tint it is coloured through and
    /// through (a wash under the glass, the glass tinted the same, a soft glow); `strength` softens that for a
    /// quieter button of the same colour.
    func chipGlass(tint: Color?, strength: Double = 1) -> some View {
        self
            .background { if let tint { Capsule().fill(tint.opacity(0.55 * strength)) } }
            .glassEffect(tint.map { .regular.tint($0.opacity(0.85 * strength)).interactive() } ?? .regular.interactive(), in: Capsule())
            .shadow(color: tint.map { $0.opacity(0.4 * strength) } ?? .clear, radius: 7, y: 2)
            .contentShape(Capsule())
    }
}

struct RoundIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 26, height: 26)
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// The small shortcut label inside a button, such as "⌥⌘Y".
struct KeyBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 4.5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.28)))
    }
}

// MARK: - Small pieces

/// A card's first row, split around the physical notch: what it is on the left, its state on the right,
/// so the space beside the camera is used instead of leaving an empty band above the card.
/// On a screen without a notch it is an ordinary row.
struct BesideNotch<Leading: View, Trailing: View>: View {
    let geometry: NotchGeometry
    let cardWidth: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if geometry.hasNotch {
            let side = geometry.besideNotchWidth(cardWidth: cardWidth)
            HStack(spacing: 0) {
                HStack(spacing: 6) { leading }.frame(width: side, alignment: .leading)
                Color.clear.frame(width: geometry.notchSize.width)
                HStack(spacing: 6) { trailing }.frame(width: side, alignment: .trailing)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(height: geometry.notchSize.height)
        } else {
            HStack(spacing: 6) { leading; Spacer(minLength: 6); trailing }
                .lineLimit(1)
                .frame(height: 24)
        }
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var color: Color = .white
    /// Just the symbol, when there is no room for the words (the words stay as the accessibility label).
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            if !compact || symbol == nil { Text(text).font(Theme.label(10.5, .semibold)).fixedSize() }
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact && symbol != nil ? 6 : 7).padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.15)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Claude's orange squircle with its asterisk.
struct ClaudeBadge: View {
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.96, green: 0.58, blue: 0.40), Color(red: 0.82, green: 0.38, blue: 0.25)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            Image(systemName: "asterisk").font(.system(size: size * 0.55, weight: .heavy)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// A spinning asterisk: Claude is working.
struct ClaudeSpinner: View {
    var size: CGFloat = 14
    @State private var spin = false
    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(Theme.claude)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .shadow(color: Theme.claude.opacity(0.7), radius: 5)
            .onAppear {
                guard !Motion.reduce else { return }
                withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.8), radius: pulsing ? 4 : 0)
            .opacity(pulsing && on ? 0.35 : 1)
            .onAppear {
                guard pulsing, !Motion.reduce else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// A grey bar that sweeps with light while Apple Intelligence is thinking.
struct ShimmerBar: View {
    var width: CGFloat = 220
    @State private var phase: CGFloat = -1
    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.10))
            .frame(width: width, height: 10)
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.5)
                        .offset(x: phase * g.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .onAppear {
                guard !Motion.reduce else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

/// A thin line along the bottom that shrinks while a card waits to disappear.
struct TimerBar: View {
    let color: Color
    let seconds: Double
    @State private var progress: CGFloat = 1
    var body: some View {
        GeometryReader { g in
            Capsule().fill(color.opacity(0.75)).frame(width: g.size.width * progress, height: 2.5)
        }
        .frame(height: 2.5)
        .onAppear { withAnimation(.linear(duration: seconds)) { progress = 0 } }
    }
}

struct AppIconView: View {
    let bundleID: String
    let size: CGFloat
    var glow = false
    var body: some View {
        Group {
            if let icon = AppLookup.icon(for: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.fill").resizable().foregroundStyle(.gray)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: glow ? AppLookup.accent(for: bundleID).opacity(0.55) : .clear, radius: glow ? 9 : 0, y: 2)
    }
}

/// A rounded panel inside the island.
struct Well<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension String {
    /// "Run a command" -> "run a command" for use inside a sentence.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}


/// The line under a player: click anywhere on it to jump there, or drag the dot to go forward or back.
/// The hit area is tall so it is easy to grab, and it takes priority over dragging the window or the card.
struct SeekBar: View {
    let fraction: Double
    let accent: Color
    let enabled: Bool
    let scrub: (Double) -> Void
    let commit: (Double) -> Void
    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            let x = min(max(fraction, 0), 1) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: hover || dragging ? 6 : 4)
                Capsule().fill(accent).frame(width: max(4, x), height: hover || dragging ? 6 : 4)
                Circle().fill(.white).frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: min(max(x - 6, 0), w - 12))
                    .opacity(enabled && (hover || dragging) ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard enabled else { return }
                    dragging = true
                    scrub(min(max(v.location.x / w, 0), 1))
                }
                .onEnded { v in
                    if enabled { commit(min(max(v.location.x / w, 0), 1)) }
                    dragging = false
                })
        }
        .frame(height: 22)
        .animation(Motion.hover, value: hover)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
