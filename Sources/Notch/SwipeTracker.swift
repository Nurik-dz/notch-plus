import AppKit

/// Turns a stream of two-finger scroll movements into one "swipe down" or "swipe up" per gesture.
/// `dy` is the finger movement, positive when the fingers move down the trackpad.
struct SwipeTracker {
    enum Swipe: Equatable { case down, up }

    private var sum = 0.0
    private var fired = false
    let threshold: Double

    init(threshold: Double = 14) { self.threshold = threshold }

    /// `began` starts a new gesture; `ended` finishes it. Returns a swipe the moment the movement is large enough.
    mutating func feed(dy: Double, began: Bool, ended: Bool) -> Swipe? {
        if began { sum = 0; fired = false }
        defer { if ended { sum = 0; fired = false } }
        guard !fired else { return nil }
        sum += dy
        if sum >= threshold { fired = true; return .down }
        if sum <= -threshold { fired = true; return .up }
        return nil
    }
}
