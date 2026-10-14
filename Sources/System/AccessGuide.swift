import AppKit
import SwiftUI

// The drag card and the System Settings window tracking are adapted from PermissionFlow by jaywcjlove
// (https://github.com/jaywcjlove/PermissionFlow), MIT License, Copyright (c) 2026 小弟调调 (jaywcjlove).
// See Vendor/THIRD_PARTY.txt. Changed for Notch+: no Accessibility prompt (the window list only),
// the Notch+ look, and the card closes by itself once access works.

/// Makes Full Disk Access one drag: opens the right page of System Settings and floats a small card
/// under its window with the Notch+ icon, which the user drags straight into the list.
@MainActor
final class AccessGuide {
    static let shared = AccessGuide()

    private var panel: NSPanel?
    private var timer: Timer?
    private var misses = 0
    private var dragging = false
    /// Says when access works, so the card can close by itself.
    private var isGranted: () -> Bool = { false }

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    func showFullDiskAccess(isGranted: @escaping () -> Bool) {
        self.isGranted = isGranted
        NSWorkspace.shared.open(Self.fullDiskAccessURL)
        let p = panel ?? makePanel()
        p.alphaValue = 0
        misses = 0
        place(p, under: nil)
        p.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func close() {
        timer?.invalidate(); timer = nil
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { p.orderOut(nil) }
        })
    }

    private func tick() {
        guard let p = panel else { return }
        if isGranted() { close(); return }
        if let frame = Self.settingsWindowFrame() {
            misses = 0
            if !dragging { place(p, under: frame) }
            if p.alphaValue == 0 { NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 } }
        } else {
            // System Settings is still opening, swapping panes, or was closed
            misses += 1
            if misses > 60 { close() }      // about three seconds without its window
        }
    }

    /// Just below the System Settings window, centred; on the screen it is on.
    private func place(_ p: NSPanel, under frame: CGRect?) {
        let size = p.frame.size
        guard let frame else {
            let s = NSScreen.main?.visibleFrame ?? .zero
            p.setFrameOrigin(CGPoint(x: s.midX - size.width / 2, y: s.midY - size.height / 2))
            return
        }
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            let v = screen.visibleFrame
            origin.y = max(origin.y, v.minY + 8)          // no room below: sit over the window's lower edge
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - size.width - 8)
        }
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 92),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let card = AccessCardView(appURL: Bundle.main.bundleURL,
                                  onDrag: { [weak self, weak p] active in
                                      self?.dragging = active
                                      p?.ignoresMouseEvents = active      // the drop must land in Settings, not on the card
                                  },
                                  onClose: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: card)
        host.sizingOptions = []          // otherwise the hosting view keeps re-sizing the panel off screen
        p.contentView = host
        panel = p
        return p
    }

    /// The System Settings window in AppKit screen coordinates, from the window list (no permission needed).
    static func settingsWindowFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first(where: { $0.activationPolicy != .prohibited }),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let best = windows.compactMap { w -> CGRect? in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d), r.width > 320, r.height > 240 else { return nil }
            return r
        }
        .max { $0.width * $0.height < $1.width * $1.height }
        return best.map(appKitFrame)
    }

    /// The window list measures from the top left of the main display; AppKit from the bottom left.
    static func appKitFrame(_ r: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - The card

private struct AccessCardView: View {
    let appURL: URL
    let onDrag: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppDragSource(url: appURL, onDrag: onDrag)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("01").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.violet)
                    Text("Drag Notch+ into the list").font(Theme.title(14)).foregroundStyle(.white)
                }
                Text("If it is already there, switch it off and on. Notch+ notices by itself.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .frame(width: 380, height: 92)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.violet.opacity(0.35), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

/// The Notch+ icon as a drag source shaped like a file dragged from Finder, which System Settings accepts.
private struct AppDragSource: NSViewRepresentable {
    let url: URL
    let onDrag: (Bool) -> Void

    func makeNSView(context: Context) -> DragView {
        let v = DragView(url: url)
        v.onDrag = onDrag
        return v
    }

    func updateNSView(_ v: DragView, context: Context) { v.onDrag = onDrag }

    final class DragView: NSView, NSDraggingSource {
        let url: URL
        var onDrag: ((Bool) -> Void)?
        private var downAt: NSPoint?
        private var started = false
        private let icon: NSImage

        init(url: URL) {
            self.url = url
            self.icon = NSWorkspace.shared.icon(forFile: url.path)
            super.init(frame: .zero)
            toolTip = "Drag me into the Full Disk Access list"
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func draw(_ dirtyRect: NSRect) {
            icon.draw(in: bounds.insetBy(dx: 2, dy: 2))
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { downAt = convert(event.locationInWindow, from: nil); started = false }
        override func mouseUp(with event: NSEvent) { downAt = nil; started = false }

        override func mouseDragged(with event: NSEvent) {
            guard !started, let downAt else { return }
            let p = convert(event.locationInWindow, from: nil)
            guard hypot(p.x - downAt.x, p.y - downAt.y) > 4 else { return }
            started = true
            let item = NSDraggingItem(pasteboardWriter: FinderLikeFile(url: url))
            item.setDraggingFrame(bounds, contents: icon)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onDrag?(true) }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onDrag?(false); downAt = nil; started = false
        }
    }
}

/// The pasteboard types a Finder file drag carries.
private final class FinderLikeFile: NSObject, NSPasteboardWriting {
    let url: URL
    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType"),
         NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"), .string]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL, NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"): url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"): [url.path]
        case .string: url.path
        default: nil
        }
    }
}
