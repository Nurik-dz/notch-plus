import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac and its screen awake, for as long as you like. One tap on, one tap off.
@MainActor
final class Caffeine: ObservableObject {
    enum Duration: CaseIterable, Identifiable {
        case untilOff, minutes15, minutes30, hour1, hours2, hours4
        var id: Self { self }
        var seconds: TimeInterval? {
            switch self {
            case .untilOff: nil
            case .minutes15: 15 * 60
            case .minutes30: 30 * 60
            case .hour1: 3600
            case .hours2: 7200
            case .hours4: 14400
            }
        }
        var title: String {
            switch self {
            case .untilOff: "Until I turn it off"
            case .minutes15: "15 minutes"
            case .minutes30: "30 minutes"
            case .hour1: "1 hour"
            case .hours2: "2 hours"
            case .hours4: "4 hours"
            }
        }
    }

    @Published private(set) var active = false
    /// When it switches itself off; nil while it runs until you turn it off.
    @Published private(set) var endsAt: Date?
    /// Called when it ends by itself (the time ran out).
    var onExpire: (() -> Void)?

    private var assertion = IOPMAssertionID(0)
    private var task: Task<Void, Never>?

    func start(_ d: Duration = .untilOff, now: Date = Date()) {
        release()
        var id = IOPMAssertionID(0)
        let ok = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Notch+ is keeping the Mac awake" as CFString, &id)
        guard ok == kIOReturnSuccess else { return }
        assertion = id
        active = true
        endsAt = d.seconds.map { now.addingTimeInterval($0) }
        task?.cancel()
        if let end = endsAt {
            task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
                if !Task.isCancelled { self?.expire() }
            }
        }
    }

    func stop() {
        task?.cancel()
        release()
        active = false
        endsAt = nil
    }

    func toggle() { active ? stop() : start() }

    private func expire() {
        stop()
        onExpire?()
    }

    private func release() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    deinit { if assertion != 0 { IOPMAssertionRelease(assertion) } }
}
