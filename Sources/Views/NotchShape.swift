import SwiftUI

/// The island's outline: the top corners flare outward into the screen edge (like the real notch
/// does), the bottom corners are round. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4, rect.height / 2)
        let br = min(bottomRadius, (rect.width - 2 * tr) / 2, rect.height - tr)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // right flare into the body
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr))
        // left flare
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
