import AppKit

/// How far the island is pulled open right now (0 closed, 1 fully open). Kept apart from the model so the many
/// frames of a pull only redraw the island itself, never the cards inside it.
@MainActor
final class PullState: ObservableObject {
    @Published var progress: CGFloat = 0
    @Published var active = false
}

/// Turns the continuous movement of two fingers into how far the island is open, and decides on release
/// whether it was meant to open or close. The island follows the fingers one to one, resists like rubber
/// past fully open, and the speed of the release counts: a quick flick finishes the move, a slow one that
/// stops short falls back.
struct PullTracker {
    /// Finger travel (points) that opens the island fully.
    static let distance = 110.0
    /// Travel before the island reacts at all, so an ordinary scroll never moves it.
    static let deadZone = 10.0
    /// How far past fully open the rubber band may stretch, in progress units.
    static let stretch = 0.28
    /// Seconds of coasting added to the release position when the move is judged.
    static let lookAhead = 0.12

    private(set) var active = false
    private var base = 0.0                 // where the pull started: 0 closed, 1 open
    private var travel = 0.0               // finger travel since the gesture began, positive downward
    private var lastTime = 0.0
    private(set) var velocity = 0.0        // progress per second, smoothed
    private var lastProgress = 0.0

    /// Starts a gesture. `open` is whether the island is open now.
    mutating func begin(open: Bool, at time: TimeInterval) {
        base = open ? 1 : 0
        travel = 0
        active = false
        velocity = 0
        lastTime = time
        lastProgress = base
    }

    /// Resistance past fully open: follows the fingers at first, then gives less and less, never passing `stretch`.
    static func rubber(_ over: Double) -> Double {
        guard over > 0 else { return 0 }
        return (1 - 1 / (over * 0.55 / stretch + 1)) * stretch
    }

    /// Display progress for a raw one (1 is fully open): linear inside, rubber band above, never below 0.
    static func display(raw: Double) -> Double {
        if raw <= 0 { return 0 }
        if raw <= 1 { return raw }
        return 1 + rubber(raw - 1)
    }

    /// Feeds finger movement (positive downward). Returns the display progress once the pull is under way.
    mutating func feed(dy: Double, at time: TimeInterval) -> Double? {
        travel += dy
        if !active {
            // opening starts with a pull down, closing with a pull up; the other direction is ignored
            let wants = base == 0 ? travel >= Self.deadZone : travel <= -Self.deadZone
            if !wants { if (base == 0 && travel < 0) || (base == 1 && travel > 0) { travel = 0 }; return nil }
            active = true
            travel -= (travel > 0 ? 1 : -1) * Self.deadZone          // start from the current position, no jump
            lastTime = time
            lastProgress = base
        }
        let p = Self.display(raw: base + travel / Self.distance)
        let dt = time - lastTime
        if dt > 0.001 {
            let v = (p - lastProgress) / dt
            velocity = velocity * 0.6 + v * 0.4
            lastTime = time
            lastProgress = p
        }
        return p
    }

    /// Whether the island should end up open: where it would coast to, judged against the middle.
    var shouldOpen: Bool {
        min(max(lastProgress + velocity * Self.lookAhead, 0), 1.2) > 0.5
    }

    mutating func end() { active = false }
}
