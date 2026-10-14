import AppKit
import SwiftUI

/// A window that never takes the keyboard and never activates the app, so a drag can end on it.
final class BasketPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The floating basket: shake the mouse while dragging files and it appears under the pointer.
/// It is another door to the shelf: dropping here puts files on the shelf, and it shows the shelf's files.
@MainActor
final class BasketController: ObservableObject {
    /// The visible basket, and the window around it with room for its soft shadow to fade out
    /// (too little room cuts the shadow off in a straight line, like a dark rectangle).
    static let shadowRoom: CGFloat = 44
    static let content = CGSize(width: 412, height: 270)
    static let size = CGSize(width: content.width + 2 * shadowRoom, height: content.height + 2 * shadowRoom)

    let model: NotchModel
    private let visibleFrame: () -> CGRect
    private(set) var panel: BasketPanel?
    private var shake = ShakeDetector()
    private var shakeStrength = ShakeDetector.Strength.normal
    private var hideWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?

    @Published private(set) var shown = false
    @Published var targeted = false           // a drag is over the basket
    var hovering = false { didSet { if hovering { cancelHide() } else if !dragActive { scheduleHide() } } }
    private(set) var dragActive = false

    init(model: NotchModel, visibleFrame: @escaping () -> CGRect = { (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame }) {
        self.model = model
        self.visibleFrame = visibleFrame
    }

    // MARK: Drag lifecycle (fed by the pointer watcher)

    /// A file drag moved. Returns true when this movement summoned the basket.
    @discardableResult
    func dragMoved(to p: CGPoint, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        dragActive = true
        guard model.basketEnabled, !shown else { return false }
        if shakeStrength != model.basketShake { shakeStrength = model.basketShake; shake = ShakeDetector.preset(shakeStrength) }
        if shake.feed(x: p.x, at: time) { show(near: p); return true }
        return false
    }

    /// The mouse button went up: the drag is over.
    func dragEnded() {
        dragActive = false
        shake.reset()
        if shown { scheduleHide() }
    }

    // MARK: Showing and hiding

    func show(near p: CGPoint) {
        orderOutWork?.cancel()
        let frame = BasketPlacement.frame(cursor: p, size: Self.size, in: visibleFrame())
        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        shown = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        // while a drag is in progress it must not vanish under the pointer
        cancelHide()
    }

    func hide() {
        cancelHide()
        guard shown else { return }
        shown = false
        targeted = false
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.shown else { return }
            self.panel?.orderOut(nil)
        }
        orderOutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)     // after the fade-out
    }

    func scheduleHide() {
        hideWork?.cancel()
        let seconds = model.basketHideSeconds
        guard shown, seconds > 0 else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hovering || self.dragActive || self.targeted { self.scheduleHide(); return }
            self.hide()
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }

    /// Files dropped on the basket go to the shelf.
    @discardableResult
    func dropped(_ urls: [URL]) -> Bool {
        let added = model.add(urls, to: model.basketList)
        if added > 0 { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        targeted = false
        scheduleHide()
        return added > 0
    }

    private func makePanel() -> BasketPanel {
        let p = BasketPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isFloatingPanel = true
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BasketView(model: model, shelf: model.shelf, own: model.basketStore, controller: self))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }
}

/// What is inside the basket window.
struct BasketView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var own: ShelfStore
    @ObservedObject var controller: BasketController
    @State private var selected: UUID?
    @State private var flying: Set<UUID> = []

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        let active = controller.targeted
        let store = model.basketSendsToShelf ? shelf : own
        ZStack {
            Color.clear.glassEffect(.regular.tint(Theme.violet.opacity(active ? 0.34 : 0.14)), in: shape)
            content(store).padding(.horizontal, 18).padding(.vertical, 14)
            GlowRim(shape: shape, accent: Theme.violet, strength: controller.shown ? (active ? 1.4 : 0.8) : 0)
        }
        .frame(width: BasketController.content.width, height: BasketController.content.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.30), radius: 14, y: 8)
        .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
        .scaleEffect(controller.shown ? 1 : 0.86, anchor: .center)
        .opacity(controller.shown ? 1 : 0)
        .animation(Motion.reduce ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.72), value: controller.shown)
        .animation(Motion.hover, value: active)
        .frame(width: BasketController.size.width, height: BasketController.size.height)
        .environment(\.colorScheme, .dark)
        .onHover { controller.hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in controller.dropped(urls) } isTargeted: { controller.targeted = $0 }
    }

    /// The chosen files (or all, when none is chosen) rise toward the notch, then land on the shelf.
    private func moveToShelf(_ list: ShelfStore) {
        let chosen = list.items.filter { model.selection.contains($0.id) }.map(\.id)
        let ids = chosen.isEmpty ? list.items.map(\.id) : chosen
        guard !ids.isEmpty, flying.isEmpty else { return }
        flying = Set(ids)
        model.showFlash(NotchModel.Flash(symbol: "tray.and.arrow.up.fill", text: ids.count == 1 ? "To shelf" : "\(ids.count) to shelf", good: true), seconds: 1.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduce ? 0.05 : 0.42)) {
            model.sendToShelf(ids)
            flying = []
        }
    }

    /// A small round glass button; lit when its switch is on.
    private func iconButton(_ symbol: String, on: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.78))
                .frame(width: 26, height: 26)
                .glassEffect(on ? .regular.tint(Theme.violet.opacity(0.6)).interactive() : .regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    @ViewBuilder private func content(_ shelf: ShelfStore) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // the count; with several files a tap on it selects them all
                Button { if shelf.items.count > 1 { model.selection.selectAll(shelf.items.map(\.id)) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.fill").foregroundStyle(Theme.violet)
                        Text(shelf.items.isEmpty ? "Basket" : "\(shelf.items.count) in the basket").font(Theme.label(12.5, .semibold))
                    }
                }
                .buttonStyle(.plain)
                .help(shelf.items.count > 1 ? "Select all the files" : "Drop files here to keep them")
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        if !model.basketSendsToShelf, !shelf.items.isEmpty {
                            iconButton("arrow.up.to.line", help: "Move to the notch shelf (the selected files, or all of them)") { moveToShelf(shelf) }
                        }
                        if !shelf.items.isEmpty {
                            iconButton("trash", help: "Empty the basket (your files are not touched)") { shelf.clear(); model.selection.clear() }
                        }
                        iconButton("xmark", help: "Close the basket") { controller.hide() }
                    }
                }
            }
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: controller.targeted ? "arrow.down.circle.fill" : "arrow.down.to.line")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(controller.targeted ? Theme.violet : Theme.tertiary)
                        .symbolEffect(.bounce, value: controller.targeted)
                    Text(controller.targeted ? "Let go to keep it here" : "Drop files here").font(Theme.label(13, .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FileGrid(model: model, store: shelf, columns: 5, maxHeight: 176, flying: flying)
                if model.selection.count > 1 {
                    FileBulkBar(model: model, store: shelf)
                } else if let item = shelf.items.first(where: { model.selection.contains($0.id) }) {
                    ShelfActionBar(model: model, shelf: shelf, item: item, allowAsk: false).id(item.id)
                }
            }
        }
    }
}
