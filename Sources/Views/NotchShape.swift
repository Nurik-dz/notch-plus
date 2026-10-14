import SwiftUI

/// The liquid layer under the island: the island's body and a small drop beside it, drawn black,
/// blurred and cut at half alpha, so while the two are close they join with a neck and pull apart like
/// liquid (the way the iPhone splits off a second Live Activity). The crisp shapes are drawn on top;
/// this layer only adds the neck. Animatable, so it is redrawn with the in-between values of the springs.
struct GooLayer: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var dropX: CGFloat         // drop centre, from the island's centre line
    var dropY: CGFloat         // drop top, from the top edge
    var dropSize: CGFloat

    static let blur: CGFloat = 6

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(dropX, AnimatablePair(dropY, dropSize))) }
        set {
            width = newValue.first.first; height = newValue.first.second
            dropX = newValue.second.first; dropY = newValue.second.second.first; dropSize = newValue.second.second.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
            ctx.addFilter(.blur(radius: Self.blur))
            ctx.drawLayer { layer in
                let mid = size.width / 2
                // the body runs up past the top edge so only its lower corners are round
                let body = CGRect(x: mid - width / 2, y: -40, width: max(width, 1), height: height + 40)
                layer.fill(Path(roundedRect: body, cornerRadius: radius, style: .continuous), with: .color(.black))
                let c = CGPoint(x: mid + dropX, y: dropY + NotchRootView.bubbleSize / 2)
                layer.fill(Path(ellipseIn: CGRect(x: c.x - dropSize / 2, y: c.y - dropSize / 2, width: dropSize, height: dropSize)),
                           with: .color(.black))
            }
        }
    }
}

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
