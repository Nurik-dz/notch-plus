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

struct PillButtonStyle: ButtonStyle {
    enum Kind { case allow, danger, deny, quiet }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(12.5, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background {
                if kind == .allow || kind == .danger { Capsule().fill(glow).blur(radius: 8).offset(y: 3) }
                Capsule().fill(fill)
            }
            .overlay { if kind == .allow || kind == .danger { Capsule().strokeBorder(stroke, lineWidth: 1) } }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .hoverLift(1.03)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .allow, .danger: .white
        case .deny: Color(red: 1.0, green: 0.55, blue: 0.52)
        case .quiet: .white.opacity(0.9)
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .allow: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.22, green: 0.80, blue: 0.42), Color(red: 0.12, green: 0.60, blue: 0.31)], startPoint: .top, endPoint: .bottom))
        case .danger: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.32), Color(red: 0.80, green: 0.2, blue: 0.2)], startPoint: .top, endPoint: .bottom))
        case .deny: AnyShapeStyle(Theme.red.opacity(0.22))
        case .quiet: AnyShapeStyle(Color.white.opacity(0.11))
        }
    }

    private var stroke: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
    }

    private var glow: Color {
        switch kind {
        case .allow: Theme.green.opacity(0.35)
        case .danger: Theme.red.opacity(0.4)
        default: .clear
        }
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

struct Chip: View {
    let text: String
    var symbol: String?
    var color: Color = .white
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(Theme.label(10.5, .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.15)))
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
