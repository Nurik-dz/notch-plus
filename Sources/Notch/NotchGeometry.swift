import AppKit

/// What the island is showing right now.
enum IslandState: Hashable {
    case closed        // just the notch (nothing on notchless screens)
    case wings         // the notch widened: a live status or a short result on each side
    case notification  // a notification from another app
    case finished      // Claude finished a long task
    case overview      // opened by the pointer
    case approval      // a request is waiting
    case result        // a file action finished (or failed)
}

/// Where the notch is and how big each state of the island is.
/// The window itself never changes size; only the drawn shape does, and open cards size themselves
/// to their content (measured), so the island always hugs what it shows.
/// Injected in tests so a notch can be faked on any screen.
struct NotchGeometry {
    var screenFrame: CGRect
    /// Physical notch size. Zero on screens without a notch.
    var notchSize: CGSize

    var hasNotch: Bool { notchSize.height > 0 }
    /// Space above the content so nothing hides behind the notch.
    var contentTopInset: CGFloat { hasNotch ? notchSize.height + 4 : 12 }

    /// Above the cards: their first row sits beside the notch, so no empty band is left under it.
    var cardTopInset: CGFloat { hasNotch ? 0 : 12 }

    static let overviewWidth: CGFloat = 500
    static let approvalWidth: CGFloat = 460
    static let notificationWidth: CGFloat = 400
    static let finishedWidth: CGFloat = 400
    static let resultWidth: CGFloat = 440
    /// Side space of the small cards (clears the flared top corners).
    static let cardSideInset: CGFloat = 28

    /// Width of each side of a row that sits beside the notch on a card of the given width.
    func besideNotchWidth(cardWidth: CGFloat, inset: CGFloat = NotchGeometry.cardSideInset) -> CGFloat {
        max((cardWidth - 2 * inset - notchSize.width) / 2, 40)
    }
    static let wingWidth: CGFloat = 104
    static let shadowPad: CGFloat = 56
    /// The tallest content any card may have; sets the size of the fixed window.
    static let maxContentHeight: CGFloat = 330

    func width(_ state: IslandState, wing: CGFloat = NotchGeometry.wingWidth) -> CGFloat {
        switch state {
        case .closed: hasNotch ? notchSize.width : 0
        case .wings: hasNotch ? notchSize.width + 2 * wing : (wing < NotchGeometry.wingWidth ? 150 : 240)
        case .notification: Self.notificationWidth
        case .finished: Self.finishedWidth
        case .result: Self.resultWidth
        case .overview: Self.overviewWidth
        case .approval: Self.approvalWidth
        }
    }

    /// A good guess for the height before the real card has been measured.
    func fallbackHeight(_ state: IslandState) -> CGFloat {
        switch state {
        case .closed: hasNotch ? notchSize.height : 0
        case .wings: hasNotch ? notchSize.height : 34     // level with the menu bar, like the notch itself
        case .notification: cardTopInset + 112
        case .finished: cardTopInset + 104
        case .result: cardTopInset + 120
        case .overview: contentTopInset + 96
        case .approval: cardTopInset + 196
        }
    }

    /// Size of the drawn shape. `height` is the measured height of the open card, when known.
    func shapeSize(_ state: IslandState, height: CGFloat? = nil, anticipating: Bool = false, wing: CGFloat = NotchGeometry.wingWidth) -> CGSize {
        var size = CGSize(width: width(state, wing: wing), height: fallbackHeight(state))
        if let height, [.notification, .finished, .overview, .approval, .result].contains(state) {
            size.height = min(height, contentTopInset + Self.maxContentHeight)
        }
        if anticipating, state == .closed, hasNotch {      // a small lean toward the pointer before opening
            size.width += 14
            size.height += 3
        }
        return size
    }

    /// The fixed window: wide and tall enough for the biggest state plus its shadow.
    var windowFrame: CGRect {
        let w = [Self.overviewWidth, Self.approvalWidth, Self.notificationWidth, Self.resultWidth].max()! + 2 * Self.shadowPad
        let h = contentTopInset + Self.maxContentHeight + Self.shadowPad
        return CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }

    /// Where the shape is on screen (top centre, flush with the top edge).
    func shapeRect(_ state: IslandState, height: CGFloat? = nil) -> CGRect {
        let s = shapeSize(state, height: height)
        return CGRect(x: screenFrame.midX - s.width / 2, y: screenFrame.maxY - s.height, width: s.width, height: s.height)
    }

    /// Area where the pointer wakes the island.
    var hotRect: CGRect {
        if hasNotch {
            let r = shapeRect(.closed)
            return CGRect(x: r.minX - 6, y: r.minY - 4, width: r.width + 12, height: r.height + 4 + 2)
        }
        return CGRect(x: screenFrame.midX - 110, y: screenFrame.maxY - 6, width: 220, height: 6)
    }

    /// The Mac's built-in notch screen if there is one, otherwise the main screen.
    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        var notch = CGSize.zero
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = (left > 0 && right > 0) ? screen.frame.width - left - right + 4 : 200
            notch = CGSize(width: width, height: screen.safeAreaInsets.top)
        }
        return NotchGeometry(screenFrame: screen.frame, notchSize: notch)
    }

    /// A pretend screen far off to the side, for tests.
    static func fake(notch: Bool) -> NotchGeometry {
        NotchGeometry(screenFrame: CGRect(x: -6000, y: 0, width: 1512, height: 982),
                      notchSize: notch ? CGSize(width: 185, height: 32) : .zero)
    }
}
