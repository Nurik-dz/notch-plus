import AppKit
import SwiftUI
import Combine

/// A small player that floats above your windows, wherever you drag it. You pull it out of the notch by dragging
/// the player down, and put it away by dragging it back up to the notch (or with its close button). It shows
/// whatever is playing, appears when something starts and tucks away when nothing is playing.
@MainActor
final class FloatingPlayerController {
    /// The window, with room for the shadow, in the full and the compact version.
    static let size = FloatingPlayerController.windowSize(compact: false)
    static func contentSize(compact: Bool) -> CGSize { compact ? CGSize(width: 258, height: 58) : CGSize(width: 340, height: 122) }
    static func windowSize(compact: Bool) -> CGSize {
        let c = contentSize(compact: compact)
        return CGSize(width: c.width + 48, height: c.height + 48)
    }
    static let snapDistance: CGFloat = 24
    static let snapMargin: CGFloat = 10

    let model: NotchModel
    private let visibleFrame: () -> CGRect
    private(set) var panel: FloatingPlayerPanel?
    private var cancellables = Set<AnyCancellable>()
    private var moveObserver: NSObjectProtocol?
    private var tracker: Timer?
    private var followOffset: CGPoint?          // set while the player is being carried by the pointer after a tear-off
    private var compactShown = false

    init(model: NotchModel, visibleFrame: @escaping () -> CGRect = { (NSScreen.main ?? NSScreen.screens[0]).visibleFrame }) {
        self.model = model
        self.visibleFrame = visibleFrame
    }

    func start() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        model.onTearOff = { [weak self] in self?.tearOff() }
        update()
    }

    /// It is shown while it is switched on and something is playing (or paused, so play can be pressed again).
    var shouldShow: Bool { model.floatingPlayerOn && model.nowPlaying?.isMeaningful == true }
    var isShown: Bool { panel?.isVisible == true }

    func update() {
        if shouldShow {
            let p = panel ?? makePanel()
            if !p.isVisible {
                compactShown = model.floatingCompact
                var f = initialFrame()
                f.size = Self.windowSize(compact: compactShown)
                p.setFrame(f, display: true)
                p.alphaValue = 0
                p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
            } else if compactShown != model.floatingCompact {
                resize(p, compact: model.floatingCompact)
            }
        } else if let p = panel, p.isVisible {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; p.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                guard let self, !self.shouldShow else { return }
                p.orderOut(nil)
            })
        }
    }

    /// Full and compact keep the same top left corner.
    private func resize(_ p: FloatingPlayerPanel, compact: Bool) {
        compactShown = compact
        let old = p.frame
        let size = Self.windowSize(compact: compact)
        let f = CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        p.setFrame(f, display: true, animate: !Motion.reduce)
    }

    /// Where it was last put, or the bottom right corner the first time.
    func initialFrame() -> CGRect {
        let screen = visibleFrame()
        let size = Self.windowSize(compact: model.floatingCompact)
        if let x = model.defaults.object(forKey: "floatingPlayerX") as? Double, let y = model.defaults.object(forKey: "floatingPlayerY") as? Double {
            var f = CGRect(x: x, y: y, width: size.width, height: size.height)
            // a screen may have been unplugged since: keep it reachable
            f.origin.x = min(max(f.origin.x, screen.minX - 40), screen.maxX - size.width + 40)
            f.origin.y = min(max(f.origin.y, screen.minY - 40), screen.maxY - size.height + 40)
            return f
        }
        return CGRect(x: screen.maxX - size.width - 12, y: screen.minY + 12, width: size.width, height: size.height)
    }

    // MARK: - Pulling it out of the notch, and putting it back

    /// The player was dragged down out of the notch: it appears under the pointer and follows it until the button is let go.
    func tearOff(at mouse: CGPoint = NSEvent.mouseLocation) {
        let p = panel ?? makePanel()
        compactShown = model.floatingCompact
        let size = Self.windowSize(compact: compactShown)
        // the pointer holds it a little below its top edge, in the middle
        let origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y + 54 - size.height)
        p.setFrame(CGRect(origin: origin, size: size), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        followOffset = CGPoint(x: mouse.x - origin.x, y: mouse.y - origin.y)
        startTracking()
    }

    /// Whether letting go here puts the player back in the notch.
    func isInDockZone(_ mouse: CGPoint) -> Bool {
        let s = visibleFrame()
        return CGRect(x: s.midX - 170, y: s.maxY - 60, width: 340, height: 400).contains(mouse)
    }

    /// While a button is held (carried after a tear-off, or dragged by hand), watch the pointer until it is let go.
    private func startTracking() {
        guard tracker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tracker = t
    }

    private func tick() {
        guard let p = panel else { stopTracking(); return }
        let mouse = NSEvent.mouseLocation
        if let off = followOffset { p.setFrameOrigin(CGPoint(x: mouse.x - off.x, y: mouse.y - off.y)) }
        p.alphaValue = isInDockZone(mouse) ? 0.5 : 1         // half see-through: letting go here puts it away
        if NSEvent.pressedMouseButtons & 1 == 0 {
            stopTracking()
            settle(mouse: mouse)
        }
    }

    private func stopTracking() {
        tracker?.invalidate(); tracker = nil
        followOffset = nil
    }

    /// The button was let go: back in the notch if it is up there, otherwise it clings to a nearby screen edge.
    func settle(mouse: CGPoint) {
        guard let p = panel else { return }
        if isInDockZone(mouse) {
            model.floatingPlayerOn = false
            return
        }
        p.alphaValue = 1
        let snapped = snapped(p.frame)
        if snapped.origin != p.frame.origin { p.setFrame(snapped, display: true, animate: !Motion.reduce) }
    }

    /// The window moved so the visible player sits `snapMargin` from any screen edge it is within `snapDistance` of.
    func snapped(_ frame: CGRect) -> CGRect {
        let screen = visibleFrame()
        let c = Self.contentSize(compact: compactShown)
        let inset = CGSize(width: (frame.width - c.width) / 2, height: (frame.height - c.height) / 2)
        let content = frame.insetBy(dx: inset.width, dy: inset.height)
        var f = frame
        let m = Self.snapMargin, d = Self.snapDistance
        if abs(content.minX - screen.minX) < d { f.origin.x += screen.minX + m - content.minX }
        else if abs(content.maxX - screen.maxX) < d { f.origin.x += screen.maxX - m - content.maxX }
        if abs(content.minY - screen.minY) < d { f.origin.y += screen.minY + m - content.minY }
        else if abs(content.maxY - screen.maxY) < d { f.origin.y += screen.maxY - m - content.maxY }
        return f
    }

    private func makePanel() -> FloatingPlayerPanel {
        let p = FloatingPlayerPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FloatingPlayerView(model: model, close: { [weak model] in model?.floatingPlayerOn = false }))
        host.sizingOptions = []
        p.contentView = host
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let f = self.panel?.frame, self.panel?.isVisible == true else { return }
                self.model.defaults.set(f.origin.x, forKey: "floatingPlayerX")
                self.model.defaults.set(f.origin.y, forKey: "floatingPlayerY")
                // moved by hand (a button is down): watch for where it is let go
                if NSEvent.pressedMouseButtons & 1 != 0 { self.startTracking() }
            }
        }
        panel = p
        return p
    }
}

/// Never takes the keyboard and never switches apps.
final class FloatingPlayerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the floating player shows.
struct FloatingPlayerView: View {
    @ObservedObject var model: NotchModel
    let close: () -> Void
    @State private var scrubbing: Double?
    @State private var hover = false

    private var compact: Bool { model.floatingCompact }
    private var np_key: Int { model.nowPlaying?.artworkKey ?? 0 }

    private var accent: Color {
        if let np = model.nowPlaying, let art = np.artwork { return ImageColor.dominant(of: art, key: "art\(np.artworkKey)") }
        return Theme.violet
    }

    var body: some View {
        let size = FloatingPlayerController.contentSize(compact: compact)
        let shape = RoundedRectangle(cornerRadius: compact ? 22 : 26, style: .continuous)
        ZStack {
            // real Liquid Glass, tinted by the cover; the cover's own colours bleed softly through it
            Color.clear.glassEffect(.regular.tint(accent.opacity(0.22)), in: shape)
            if let np = model.nowPlaying, let art = np.artwork, !Motion.lessTransparency {
                Image(nsImage: AmbientArt.image(for: art, key: "amb\(np.artworkKey)"))
                    .resizable().interpolation(.high).scaledToFill()
                    .saturation(1.4).opacity(0.30)
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .id(np.artworkKey).transition(.opacity)
            }
            if let np = model.nowPlaying { (compact ? AnyView(compactContent(np)) : AnyView(content(np))) }
            GlowRim(shape: shape, accent: accent, strength: model.glowLevel.factor * 0.6 * (Motion.lessTransparency ? 0.35 : 1))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        .animation(.easeInOut(duration: 0.5), value: np_key)
        .contentShape(shape)
        .gesture(WindowDragGesture())                    // drag it by any part that is not a button
        .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(Motion.resize) { model.floatingCompact.toggle() } })
        .contextMenu {
            Button(compact ? "Full size" : "Compact") { withAnimation(Motion.resize) { model.floatingCompact.toggle() } }
            Button("Put away", action: close)
        }
        .overlay(alignment: .topLeading) { closeBadge }
        .frame(width: FloatingPlayerController.windowSize(compact: compact).width, height: FloatingPlayerController.windowSize(compact: compact).height)
        .environment(\.colorScheme, .dark)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .animation(Motion.resize, value: compact)
    }

    private func artwork(_ np: NowPlayingInfo, side: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let img = np.artwork { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
            else {
                ZStack {
                    LinearGradient(colors: [Theme.violet.opacity(0.6), Theme.blue.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .id(np.artworkKey)
        .transition(.opacity)
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: accent.opacity(0.45), radius: 8, y: 2)
        .scaleEffect(np.playing ? 1 : 0.94)
        .animation(Motion.resize, value: np.playing)
        .animation(.easeInOut(duration: 0.3), value: np.artworkKey)
    }

    private func playButton(_ np: NowPlayingInfo, side: CGFloat) -> some View {
        Button { model.sendMedia(.togglePlayPause) } label: {
            Image(systemName: np.playing ? "pause.fill" : "play.fill")
                .font(.system(size: side * 0.4, weight: .bold)).foregroundStyle(.white)
                .frame(width: side, height: side)
                .glassEffect(.regular.tint(accent.opacity(0.55)).interactive(), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain).accessibilityLabel(np.playing ? "Pause" : "Play")
    }

    /// One small dot on the top left corner, only while the pointer is over the player, like a widget's remove badge.
    /// Nothing else sits on top of the controls.
    private var closeBadge: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 18, height: 18)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(hover ? 1 : 0)
        .scaleEffect(hover ? 1 : 0.6)
        .offset(x: -6, y: -6)
        .accessibilityLabel("Put the floating player away")
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.9)).hoverLift(1.12).accessibilityLabel(label)
    }

    /// Cover and words on the left, play on the right. Nothing else.
    private func compactContent(_ np: NowPlayingInfo) -> some View {
        HStack(spacing: 11) {
            artwork(np, side: 40, radius: 10)
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: np.title, font: Theme.title(12.5), height: 17)
                Text(np.artist).font(Theme.text(10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            playButton(np, side: 32)
        }
        .padding(.leading, 9).padding(.trailing, 12)
    }

    /// The cover; to its right the words, with the three transport buttons under them; the progress line along the bottom.
    private func content(_ np: NowPlayingInfo) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                artwork(np, side: 70, radius: 12)
                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(text: np.title, font: Theme.title(14.5), height: 20)
                    Text([np.artist, np.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).lineLimit(1).padding(.top, 1)
                    Spacer(minLength: 0)
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 6) {
                            transportButton("backward.fill", label: "Previous track") { model.sendMedia(.previous) }
                            playButton(np, side: 36)
                            transportButton("forward.fill", label: "Next track") { model.sendMedia(.next) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 70)
            }
            progress(np)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func progress(_ np: NowPlayingInfo) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let total = max(np.duration, 0)
            let now = scrubbing ?? np.elapsedNow(ctx.date)
            let fraction = total > 0 ? min(max(now / total, 0), 1) : 0
            HStack(spacing: 8) {
                Text(Elapsed.clock(now)).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.tertiary)
                SeekBar(fraction: fraction, accent: accent, enabled: total > 0,
                        scrub: { scrubbing = $0 * total },
                        commit: { model.seekMedia(to: $0 * total); DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scrubbing = nil } })
                Text(total > 0 ? "-" + Elapsed.clock(total - now) : "").font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}
