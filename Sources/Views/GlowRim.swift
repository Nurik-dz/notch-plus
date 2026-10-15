import SwiftUI

/// A slow, living light along the island's edge, a little like Siri: a band of soft colours flows past,
/// glowing inward from the rim and sharp along it. The colours lean toward the card's own colour.
/// It fades out toward the top so the part next to the real notch stays pure black.
struct GlowRim<S: Shape>: View {
    let shape: S
    let accent: Color
    /// 0 is off; 1 is the full glow of an open card.
    let strength: Double
    /// Seconds for the colours to travel one full width.
    var period: Double = 9
    private var palette: [Color] {
        let base: [Color] = [
            Color(red: 0.30, green: 0.52, blue: 1.00),   // blue
            Color(red: 0.68, green: 0.42, blue: 1.00),   // violet
            Color(red: 1.00, green: 0.42, blue: 0.72),   // pink
            Color(red: 1.00, green: 0.62, blue: 0.32),   // orange
            Color(red: 0.28, green: 0.86, blue: 1.00),   // cyan
        ]
        let mixed = base.map { $0.mix(with: accent, by: 0.16) }
        return mixed + [mixed[0]]                         // starts and ends alike, so it repeats without a seam
    }

    var body: some View {
        let calm = Motion.reduce
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: calm || strength <= 0)) { ctx in
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let t = calm ? 0 : ctx.date.timeIntervalSinceReferenceDate
                let shift = CGFloat((t / period).truncatingRemainder(dividingBy: 1)) * w
                // three copies side by side, slid left; when one width has passed it looks exactly the same
                let band = HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        LinearGradient(colors: palette, startPoint: .leading, endPoint: .trailing).frame(width: w, height: h)
                    }
                }
                .offset(x: -shift - w)
                .frame(width: w, height: h, alignment: .leading)
                ZStack {
                    band.mask { shape.stroke(lineWidth: 10).blur(radius: 7) }           // light spilling a little into the glass
                        .opacity(0.38 * strength)
                        .blendMode(.plusLighter)
                    band.mask { shape.stroke(lineWidth: 1.3) }                          // the bright edge, like light caught on glass
                        .opacity(0.9 * strength)
                        .blendMode(.plusLighter)
                }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.04),
                                           .init(color: .black, location: 0.26), .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .allowsHitTesting(false)
    }
}
