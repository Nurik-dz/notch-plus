import AppKit

/// Turns a stream of two-finger scroll movements into one swipe per gesture: down, up, left or right.
/// `dy` is the finger movement, positive when the fingers move down the trackpad; `dx` is positive to the right.
/// Sideways swipes need a longer movement that is clearly more sideways than up or down, so a slanted scroll never skips a song.
struct SwipeTracker {
    enum Swipe: Equatable { case down, up, left, right }

    private var sum = 0.0
    private var sumX = 0.0
    private var fired = false
    let threshold: Double
    let sidewaysThreshold: Double

    init(threshold: Double = 14, sidewaysThreshold: Double = 40) {
        self.threshold = threshold
        self.sidewaysThreshold = sidewaysThreshold
    }

    /// `began` starts a new gesture; `ended` finishes it. Returns a swipe the moment the movement is large enough.
    mutating func feed(dx: Double = 0, dy: Double, began: Bool, ended: Bool) -> Swipe? {
        if began { sum = 0; sumX = 0; fired = false }
        defer { if ended { sum = 0; sumX = 0; fired = false } }
        guard !fired else { return nil }
        sum += dy
        sumX += dx
        if abs(sumX) >= sidewaysThreshold, abs(sumX) > abs(sum) * 2 { fired = true; return sumX < 0 ? .left : .right }
        if abs(sum) >= threshold, abs(sum) > abs(sumX) * 0.7 || sumX == 0 {
            fired = true
            return sum > 0 ? .down : .up
        }
        return nil
    }
}
