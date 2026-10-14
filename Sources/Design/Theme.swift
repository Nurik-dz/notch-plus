import SwiftUI
import AppKit
import CoreImage

/// Colours and type in one place so every card looks like part of one app.
enum Theme {
    static let claude = Color(red: 0.93, green: 0.50, blue: 0.33)
    static let blue = Color(red: 0.31, green: 0.58, blue: 1.0)
    static let green = Color(red: 0.25, green: 0.84, blue: 0.45)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let red = Color(red: 1.0, green: 0.38, blue: 0.35)
    static let violet = Color(red: 0.66, green: 0.52, blue: 1.0)

    static let hairline = Color.white.opacity(0.09)
    static let well = Color.white.opacity(0.06)       // the inset panels inside the island
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)

    static func title(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func label(_ size: CGFloat = 12, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .rounded) }
    static func text(_ size: CGFloat = 12.5) -> Font { .system(size: size) }
    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, design: .monospaced) }
}

/// All animation values in one file (Droppy's audit found hundreds of drifting copies).
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Reduce Transparency is on: calmer glow, no blurred cover glow or glass sheen.
    static var lessTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    /// Slightly slower on 60 Hz screens so frame stepping is less visible.
    private static var scale: Double {
        let fps = NSScreen.main?.maximumFramesPerSecond ?? 60
        return fps >= 100 ? 1.0 : 1.12
    }

    /// How the island's shape changes size: a calm grow with a hint of bounce when something arrives,
    /// no overshoot when it leaves.
    static func spring(for state: IslandState) -> Animation {
        if reduce { return .easeOut(duration: 0.2) }
        switch state {
        case .approval, .notification, .finished, .result: return .spring(response: 0.40 * scale, dampingFraction: 0.85)
        case .overview: return .spring(response: 0.46 * scale, dampingFraction: 0.82)
        case .wings: return .spring(response: 0.40 * scale, dampingFraction: 0.78)
        case .closed: return .spring(response: 0.46 * scale, dampingFraction: 1.0)   // no overshoot below the notch
        }
    }

    /// The music drop splitting off the island and melting back: a little looser, so the neck reads as liquid.
    static var drop: Animation { reduce ? .easeOut(duration: 0.2) : .spring(response: 0.5 * scale, dampingFraction: 0.72) }

    /// When a card's own height changes (a line of text arrives): a soft, slightly slower settle.
    static var resize: Animation { reduce ? .easeOut(duration: 0.15) : .spring(response: 0.38 * scale, dampingFraction: 0.86) }
    static var press: Animation { .easeOut(duration: 0.12) }
    static var hover: Animation { .easeOut(duration: 0.16) }
    /// Cards swapping places.
    static var content: Animation { reduce ? .easeOut(duration: 0.15) : .smooth(duration: 0.38) }
    /// Parts of a card arriving one after another.
    static func rise(_ index: Int) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(response: 0.46, dampingFraction: 0.86).delay(0.06 + 0.045 * Double(index))
    }
}

/// A tiny copy of the cover, scaled up smoothly into a soft blurred glow (cheap: no blur filter to run every frame).
/// Small ready-made pictures of a cover, made once and kept: drawing them costs almost nothing, unlike blurring or
/// scaling the full cover again on every animation frame.
enum ArtImages {
    private static var cache: [String: NSImage] = [:]
    private static let context = CIContext()

    /// The cover scaled to `side` points (kept at 2x), optionally blurred, as a plain bitmap.
    static func scaled(_ art: NSImage, side: CGFloat, blur: Double = 0, key: String) -> NSImage {
        let id = "\(key)|\(Int(side))|\(blur)"
        if let c = cache[id] { return c }
        let px = Int(side * 2)
        var result = art
        if let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
            if var out = ctx.makeImage() {
                if blur > 0 {
                    let ci = CIImage(cgImage: out)
                    if let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: ci.clampedToExtent(), kCIInputRadiusKey: blur * 2]),
                       let blurred = f.outputImage?.cropped(to: ci.extent), let baked = context.createCGImage(blurred, from: ci.extent) {
                        out = baked
                    }
                }
                result = NSImage(cgImage: out, size: NSSize(width: side, height: side))
            }
        }
        if cache.count > 60 { cache.removeAll() }
        cache[id] = result
        return result
    }
}

/// The heavily blurred copy that glows behind the open island (made once, as a bitmap).
enum AmbientArt {
    static func image(for art: NSImage, key: String) -> NSImage {
        ArtImages.scaled(art, side: 64, blur: 7, key: key)
    }
}

/// Where a long line of text should be while it slowly scrolls to show its end and back: 0 is the start, 1 the end.
enum Marquee {
    static func fraction(at t: TimeInterval, overflow: CGFloat, speed: CGFloat = 26, hold: TimeInterval = 1.8) -> CGFloat {
        guard overflow > 0 else { return 0 }
        let travel = TimeInterval(overflow / speed)
        let cycle = 2 * (hold + travel)
        let u = t.truncatingRemainder(dividingBy: cycle)
        if u < hold { return 0 }
        if u < hold + travel { return smooth(CGFloat((u - hold) / travel)) }
        if u < 2 * hold + travel { return 1 }
        return 1 - smooth(CGFloat((u - 2 * hold - travel) / travel))
    }
    private static func smooth(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
}

/// One line of text that scrolls gently when it does not fit.
struct MarqueeText: View {
    let text: String
    let font: Font
    var height: CGFloat = 20
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    var body: some View {
        let overflow = max(0, textWidth - boxWidth)
        // the text sits in an overlay, so its full width never pushes the layout wider
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .leading) {
                if overflow > 1 && !Motion.reduce {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        let f = Marquee.fraction(at: ctx.date.timeIntervalSinceReferenceDate, overflow: overflow)
                        label.offset(x: -overflow * f)
                    }
                } else {
                    label
                }
            }
            .clipped()
        .mask {
            // soft edges only when there is more text than room
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: overflow > 1 ? 8 : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: overflow > 1 ? 14 : 0)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
    }

    private var label: some View {
        Text(text).font(font).lineLimit(1).fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
    }
}

/// The colour that best stands for an app icon, used to tint glow around notifications.
enum ImageColor {
    private static var cache: [String: Color] = [:]

    static func dominant(of image: NSImage, key: String) -> Color {
        if let c = cache[key] { return c }
        let color = compute(image) ?? Theme.blue
        cache[key] = color
        return color
    }

    private static var lightCache: [String: Bool] = [:]

    /// Whether the bottom edge of the picture is light (so a line drawn over it should be dark).
    static func bottomIsLight(of image: NSImage, key: String) -> Bool {
        if let c = lightCache[key] { return c }
        let side = 24
        var light = false
        if let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = ctx.data {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
            var sum = 0.0, n = 0.0
            for row in (side - 4)..<side {                  // the last rows of the buffer are the bottom of the picture
                for col in 0..<side {
                    let i = (row * side + col) * 4
                    sum += (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
                    n += 1
                }
            }
            light = n > 0 && sum / n > 0.6
        }
        lightCache[key] = light
        return light
    }

    private static func compute(_ image: NSImage) -> Color? {
        let side = 24
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in 0..<(side * side) {
            let a = Double(px[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let rr = Double(px[i * 4]) / 255 / a, gg = Double(px[i * 4 + 1]) / 255 / a, bb = Double(px[i * 4 + 2]) / 255 / a
            let mx = max(rr, gg, bb), mn = min(rr, gg, bb)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            let w = sat * sat * a + 0.01      // vivid pixels count most
            r += rr * w; g += gg * w; b += bb * w; weight += w
        }
        guard weight > 0 else { return nil }
        return Color(red: r / weight, green: g / weight, blue: b / weight)
    }
}

// MARK: - Transitions

/// Apple-style swap: the old card blurs and fades while it shrinks a touch, the new one sharpens in.
struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 9 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.95 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}

/// A part of a card that floats up into place a moment after the card opens.
struct Rise: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 7)
            .blur(radius: shown ? 0 : 3)
            .onAppear { withAnimation(Motion.rise(index)) { shown = true } }
    }
}

extension View {
    func rise(_ index: Int) -> some View { modifier(Rise(index: index)) }

    /// A gentle lift when the pointer is over it.
    func hoverLift(_ amount: CGFloat = 1.02) -> some View { modifier(HoverLift(amount: amount)) }
}

struct HoverLift: ViewModifier {
    let amount: CGFloat
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(over ? amount : 1)
            .brightness(over ? 0.07 : 0)
            .onHover { h in withAnimation(Motion.hover) { over = h } }
    }
}
