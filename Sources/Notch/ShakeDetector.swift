import AppKit

/// Notices a quick left-and-right shake of the pointer while files are being dragged.
/// A shake is several sweeps in opposite directions, each at least `minTravel` points wide, inside `window` seconds.
struct ShakeDetector {
    enum Strength: String, CaseIterable, Identifiable {
        case easy, normal, firm
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    static func preset(_ s: Strength) -> ShakeDetector {
        switch s {
        case .easy: ShakeDetector(window: 1.0, minTravel: 38, hysteresis: 10, sweeps: 3)
        case .normal: ShakeDetector()
        case .firm: ShakeDetector(window: 0.8, minTravel: 80, hysteresis: 18, sweeps: 5)
        }
    }

    let window: TimeInterval
    let minTravel: CGFloat
    let hysteresis: CGFloat
    let sweeps: Int

    private var samples: [(t: TimeInterval, x: CGFloat)] = []

    init(window: TimeInterval = 0.9, minTravel: CGFloat = 55, hysteresis: CGFloat = 14, sweeps: Int = 4) {
        self.window = window
        self.minTravel = minTravel
        self.hysteresis = hysteresis
        self.sweeps = sweeps
    }

    mutating func reset() { samples = [] }

    /// Feed the pointer's horizontal position; true at the moment a shake is recognised.
    mutating func feed(x: CGFloat, at t: TimeInterval) -> Bool {
        samples.append((t, x))
        samples.removeAll { t - $0.t > window }
        guard samples.count >= 4 else { return false }

        var found = 0
        var dir = 0                       // +1 moving right, -1 moving left
        var segStart = samples[0].x
        var extreme = samples[0].x
        for s in samples.dropFirst() {
            if dir == 0 {
                if abs(s.x - extreme) >= hysteresis { dir = s.x > extreme ? 1 : -1; extreme = s.x }
                continue
            }
            let beyond = dir > 0 ? s.x > extreme : s.x < extreme
            if beyond { extreme = s.x; continue }
            if abs(s.x - extreme) >= hysteresis {              // turned around: the sweep that just ended
                if abs(extreme - segStart) >= minTravel { found += 1 }
                segStart = extreme
                extreme = s.x
                dir = -dir
            }
        }
        if dir != 0, abs(extreme - segStart) >= minTravel { found += 1 }     // the sweep still in progress
        if found >= sweeps { reset(); return true }
        return false
    }
}

/// Where the basket appears: centred on the pointer, kept fully on the screen.
enum BasketPlacement {
    static func frame(cursor: CGPoint, size: CGSize, in screen: CGRect, margin: CGFloat = 10) -> CGRect {
        var x = cursor.x - size.width / 2
        var y = cursor.y - size.height / 2 + 18        // a little above the pointer, so the file you carry is over the basket
        x = min(max(x, screen.minX + margin), screen.maxX - size.width - margin)
        y = min(max(y, screen.minY + margin), screen.maxY - size.height - margin)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
