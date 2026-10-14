import AppKit
import SwiftUI
import Combine

/// A panel that never takes keyboard focus from the app you are working in,
/// and that macOS never pushes below the menu bar.
final class NotchPanel: NSPanel {
    /// Only while a question box is open; the app you are working in keeps its focus the rest of the time.
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The window is fixed in size and sits at the top centre of the screen.
/// Only the shape drawn inside it grows and shrinks (SwiftUI springs), so the motion stays smooth.
@MainActor
final class NotchWindowController {
    let model: NotchModel
    private(set) var geometry: NotchGeometry
    let panel: NotchPanel
    private let liveMouse: Bool
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var monitors: [Any] = []
    /// Called while files are being dragged (for the floating basket), and when the drag ends.
    var onFileDrag: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    /// `liveMouse` is false in tests: no pointer watching, no real screen.
    init(model: NotchModel, geometry: NotchGeometry, liveMouse: Bool = true, openSettings: @escaping () -> Void) {
        self.model = model
        self.geometry = geometry
        self.liveMouse = liveMouse
        self.openSettings = openSettings

        panel = NotchPanel(contentRect: geometry.windowFrame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        installContent()
        panel.setFrame(geometry.windowFrame, display: true)
        panel.orderFrontRegardless()
        updateMouseHandling()

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMouseHandling() }
            .store(in: &cancellables)

        if liveMouse { startWatchingMouse() }
    }

    private func installContent() {
        let host = NSHostingView(rootView: NotchRootView(model: model, geometry: geometry, openSettings: openSettings))
        host.sizingOptions = []
        panel.contentView = host
    }

    func updateGeometry(_ g: NotchGeometry) {
        geometry = g
        installContent()
        panel.setFrame(g.windowFrame, display: true)
        updateMouseHandling()
    }

    /// Only an open island takes clicks; otherwise everything passes straight through.
    private func updateMouseHandling() {
        panel.ignoresMouseEvents = !model.isOpen
        // typing needs the keyboard: only while a question box is open on an open island
        if model.asking != nil, !(model.state == .overview) { model.asking = nil }
        if model.replying != nil, model.state != .notification { model.replying = nil }
        let wantsKeys = model.asking != nil || model.replying != nil
        if panel.acceptsKeyboard != wantsKeys {
            panel.acceptsKeyboard = wantsKeys
            if wantsKeys { panel.makeKey() } else if panel.isKeyWindow { panel.resignKey() }
        }
    }

    // MARK: - Pointer

    private func startWatchingMouse() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in handler(e); return e }) {
            monitors.append(local)
        }
        // Two fingers down over the notch open it, two fingers up close it.
        let scrolled: (NSEvent) -> Void = { [weak self] e in
            guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }      // trackpad only; the coasting after the fingers lift is ignored
            let dy = e.isDirectionInvertedFromDevice ? Double(e.scrollingDeltaY) : -Double(e.scrollingDeltaY)
            let dx = e.isDirectionInvertedFromDevice ? Double(e.scrollingDeltaX) : -Double(e.scrollingDeltaX)
            let began = e.phase.contains(.began) || e.phase.contains(.mayBegin)
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            Task { @MainActor in self?.swiped(dx: dx, dy: dy, began: began, ended: ended) }
        }
        if let s = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: scrolled) { monitors.append(s) }
        // an open island takes the events itself, so watch those too (and let them carry on to the shelf's list)
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { e in scrolled(e); return e }) { monitors.append(l) }
        // A click in another app means you are done asking: give the keyboard back.
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                if self?.model.asking != nil { self?.model.asking = nil }
                if self?.model.replying != nil { self?.model.leaveReply() }
            }
        }) { monitors.append(click) }
        // When the button is let go the drop has happened; give it a moment, then close the shelf.
        if let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            Task { @MainActor in self?.onDragEnd?() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { Task { @MainActor in self?.model.dragging = false } }
        }) { monitors.append(up) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // macOS reports screen changes a little late, so wait before rebuilding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Task { @MainActor in self?.updateGeometry(NotchGeometry.current()) }
            }
        }
    }

    private var swipe = SwipeTracker()

    private func swiped(dx: Double, dy: Double, began: Bool, ended: Bool) {
        let p = NSEvent.mouseLocation
        let onIsland = geometry.hotRect.insetBy(dx: -40, dy: -20).contains(p)
            || (model.hovering && geometry.shapeRect(.overview, height: model.contentHeights[.overview]).contains(p))
        guard onIsland else { _ = swipe.feed(dy: 0, began: began, ended: true); return }
        guard let s = swipe.feed(dx: dx, dy: dy, began: began, ended: ended) else { return }
        switch s {
        case .left where model.swipeSkips, .right where model.swipeSkips:
            model.skipBySwipe(next: s == .right)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .down where !model.hovering:
            openWork?.cancel(); openWork = nil
            model.anticipating = false
            model.hovering = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .up where model.hovering:
            closeWork?.cancel(); closeWork = nil
            model.hovering = false
        default: break
        }
    }

    private func pointerMoved() {
        let p = NSEvent.mouseLocation

        // A file is being dragged: open the shelf when it nears the notch, close it when it goes away.
        if NSEvent.pressedMouseButtons & 1 != 0, DragDetector.carriesFiles() {
            onFileDrag?(p)
            let near = geometry.hotRect.insetBy(dx: -50, dy: -50).contains(p)
            let inside = geometry.shapeRect(.overview, height: model.contentHeights[.overview]).insetBy(dx: -24, dy: -24).contains(p)
            if !model.dragging, near, model.shelfOpensOnDrag {
                model.anticipating = false
                model.dragging = true
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } else if model.dragging, !near, !inside {
                model.dragging = false
            }
            return
        }
        if model.dragging, NSEvent.pressedMouseButtons & 1 == 0 { model.dragging = false }

        if model.hovering {
            let keepOpen = model.asking != nil     // never close on someone who is typing
                || geometry.shapeRect(.overview, height: model.contentHeights[.overview]).insetBy(dx: -16, dy: -16).contains(p) || geometry.hotRect.contains(p)
            if keepOpen {
                closeWork?.cancel(); closeWork = nil
            } else if closeWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    self?.closeWork = nil
                    self?.model.hovering = false
                }
                closeWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
        } else if geometry.hotRect.contains(p) {
            if !model.anticipating { model.anticipating = true }
            if openWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openWork = nil
                    if self.geometry.hotRect.contains(NSEvent.mouseLocation) {
                        self.model.anticipating = false
                        self.model.hovering = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
                openWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
            }
        } else {
            openWork?.cancel(); openWork = nil
            if model.anticipating { model.anticipating = false }
        }
    }
}
