import AppKit
import SwiftUI
import Combine

/// A small player that floats above your windows, wherever you drag it. You pull it out of the notch by dragging
/// the player down, and put it away by dragging it back up to the notch (or with its close button). It shows
/// whatever is playing, appears when something starts and tucks away when nothing is playing.
@MainActor
final class FloatingPlayerController {
    /// The window, with room for the shadow, in the full and the compact version.
    static let size = FloatingPlayerController.windowSize(.large)
    static func contentSize(_ size: NotchModel.FloatingSize) -> CGSize {
        switch size {
        case .compact: CGSize(width: 258, height: 58)
        case .full: CGSize(width: 340, height: 122)
        case .large: CGSize(width: 300, height: 420)
        }
    }
    /// Space around the card inside the window, so its soft shadow fades out fully instead of being cut off in a straight line.
    static let shadowRoom: CGFloat = 44
    static func windowSize(_ size: NotchModel.FloatingSize) -> CGSize {
        let c = contentSize(size)
        return CGSize(width: c.width + 2 * shadowRoom, height: c.height + 2 * shadowRoom)
    }
    static func contentSize(compact: Bool) -> CGSize { contentSize(compact ? .compact : .full) }
    static func windowSize(compact: Bool) -> CGSize { windowSize(compact ? .compact : .full) }
    static let snapDistance: CGFloat = 24
    static let snapMargin: CGFloat = 10

    let model: NotchModel
    private let visibleFrame: () -> CGRect
    private(set) var panel: FloatingPlayerPanel?
    private var cancellables = Set<AnyCancellable>()
    private var moveObserver: NSObjectProtocol?
    private var tracker: Timer?
    private var followOffset: CGPoint?          // set while the player is being carried by the pointer after a tear-off
    private var shownSize: NotchModel.FloatingSize = .compact

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
                shownSize = model.floatingSize
                var f = initialFrame()
                f.size = Self.windowSize(shownSize)
                p.setFrame(f, display: true)
                p.alphaValue = 0
                p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
            } else if shownSize != model.floatingSize {
                resize(p, to: model.floatingSize)
            }
        } else if let p = panel, p.isVisible {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; p.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                guard let self, !self.shouldShow else { return }
                p.orderOut(nil)
            })
        }
    }

    /// Every size keeps the same top left corner.
    private func resize(_ p: FloatingPlayerPanel, to newSize: NotchModel.FloatingSize) {
        shownSize = newSize
        let old = p.frame
        let size = Self.windowSize(newSize)
        let f = CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        p.setFrame(f, display: true, animate: !Motion.reduce)
    }

    /// Where it was last put, or the bottom right corner the first time.
    func initialFrame() -> CGRect {
        let screen = visibleFrame()
        let size = Self.windowSize(model.floatingSize)
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
        shownSize = model.floatingSize
        let size = Self.windowSize(shownSize)
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
        let c = Self.contentSize(shownSize)
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
    @State private var info: MusicTrackInfo?
    @State private var controls: MusicControls?
    @State private var panel: Panel = .none
    private enum Panel { case none, lyrics, list }

    private var size: NotchModel.FloatingSize { model.floatingSize }
    private var compact: Bool { size == .compact }
    private var large: Bool { size == .large }
    private var np_key: Int { model.nowPlaying?.artworkKey ?? 0 }

    /// Changes when the song changes; the large size asks Music about the song then (and only then).
    private var infoKey: String {
        guard large, let np = model.nowPlaying, np.bundleID == MusicLibrary.bundleID else { return "off" }
        return "\(np.title)|\(np.artist)|\(np.duration)"
    }
    /// What Music told about this very song (never an earlier song's words).
    private var songInfo: MusicTrackInfo? { info?.key == infoKey ? info : nil }

    private var accent: Color {
        if let np = model.nowPlaying, let art = np.artwork { return ImageColor.dominant(of: art, key: "art\(np.artworkKey)") }
        return Theme.violet
    }

    var body: some View {
        let size = FloatingPlayerController.contentSize(self.size)
        let shape = RoundedRectangle(cornerRadius: compact ? 22 : (large ? 30 : 26), style: .continuous)
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
            if let np = model.nowPlaying {
                switch self.size {
                case .compact: compactContent(np)
                case .full: content(np)
                case .large: largeContent(np, size: size)
                }
            }
            GlowRim(shape: shape, accent: accent, strength: model.glowLevel.factor * 0.6 * (Motion.lessTransparency ? 0.35 : 1))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.20), radius: 14, y: 8)
        .shadow(color: .black.opacity(0.16), radius: 2.5, y: 1)
        .animation(.easeInOut(duration: 0.5), value: np_key)
        .contentShape(shape)
        .gesture(WindowDragGesture())                    // drag it by any part that is not a button
        .simultaneousGesture(TapGesture(count: 2).onEnded { if panel == .none || !large { withAnimation(Motion.resize) { model.nextFloatingSize() } } })
        .contextMenu {
            Button("Small") { withAnimation(Motion.resize) { model.floatingSize = .compact } }
            Button("Medium") { withAnimation(Motion.resize) { model.floatingSize = .full } }
            Button("Large") { withAnimation(Motion.resize) { model.floatingSize = .large } }
            Divider()
            Button("Put away", action: close)
        }
        .frame(width: FloatingPlayerController.windowSize(self.size).width, height: FloatingPlayerController.windowSize(self.size).height)
        .environment(\.colorScheme, .dark)
        .onHover { hover = $0 }
        .task(id: infoKey) {
            guard infoKey != "off" else { info = nil; return }
            controls = await MusicLibrary.controls()
            info = await MusicLibrary.fetch(key: infoKey)
        }
        .animation(Motion.hover, value: hover)
        .animation(.easeInOut(duration: 0.3), value: hover)
        .animation(Motion.resize, value: size)
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

    private func transportButton(_ symbol: String, label: String, side: CGFloat = 30, icon: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: icon, weight: .semibold)).frame(width: side, height: side).contentShape(Rectangle()) }
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

    /// The cover fills the top and melts into its own colours below; the words, the progress line and the three
    /// buttons sit on that. Nothing more: no stars, no lyrics, no queue.
    private func largeContent(_ np: NowPlayingInfo, size: CGSize) -> some View {
        // Away from it, nothing but the cover (filling the card) and a thin line for the time; the pointer brings the rest back.
        let chrome = hover
        let panelOpen = panel != .none
        return ZStack(alignment: .top) {
            Group {
                if let img = np.artwork {
                    ZStack {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        // under words or a list: a ready-made, lightly blurred, darker copy fades in (no live blur while animating)
                        Image(nsImage: ArtImages.scaled(img, side: 160, blur: 2.5, key: "soft\(np.artworkKey)"))
                            .resizable().aspectRatio(contentMode: .fill)
                            .overlay(Color.black.opacity(0.38))
                            .opacity(panelOpen ? 1 : 0)
                    }
                } else {
                    ZStack {
                        LinearGradient(colors: [Theme.violet.opacity(0.6), Theme.blue.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .frame(width: size.width, height: chrome ? size.width : size.height)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: chrome ? 0.62 : 1),
                                         .init(color: chrome ? .clear : .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .animation(.easeInOut(duration: 0.35), value: panelOpen)
            .id(np.artworkKey).transition(.opacity)
            .scaleEffect(np.playing ? 1 : 0.97)
            .animation(Motion.resize, value: np.playing)

            // the words or the list: ONE view that never rebuilds and always fills the card; it only glides (the line it centres on
            // moves up when the controls come in) while the controls fade, so nothing jumps
            if let si = songInfo, panel == .lyrics, !si.lyrics.isEmpty {
                LyricsView(lines: si.lyrics, now: { np.elapsedNow() }, accent: accent, anchorY: chrome ? 0.3 : 0.5, fadeAt: chrome ? 0.56 : 1)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            } else if let si = songInfo, panel == .list, !si.tracks.isEmpty {
                TrackListView(tracks: si.tracks, currentID: si.currentID, accent: accent, isPlaying: np.playing, cover: np.artwork.map { ArtImages.scaled($0, side: 76, key: "thumb\(np.artworkKey)") },
                              anchorY: chrome ? 0.3 : 0.5, fadeAt: chrome ? 0.56 : 1) { MusicLibrary.play(id: $0.id) }
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 10) {
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeText(text: np.title, font: Theme.title(17), height: 23)
                        Text([np.artist, np.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Theme.text(12.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .compositingGroup()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    if let c = controls { MediaSwitches(controls: c, accent: accent, size: 28) { controls = $0 } }
                }
                progress(np)
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 12) {
                        panelButton(.lyrics, symbol: "quote.bubble", label: "Lyrics", available: songInfo?.lyrics.isEmpty == false)
                        transportButton("backward.fill", label: "Previous track", side: 40, icon: 19) { model.sendMedia(.previous) }
                        playButton(np, side: 58)
                        transportButton("forward.fill", label: "Next track", side: 40, icon: 19) { model.sendMedia(.next) }
                        panelButton(.list, symbol: "list.bullet", label: "Songs on this album", available: songInfo?.tracks.isEmpty == false)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
            .opacity(chrome ? 1 : 0)
            .allowsHitTesting(chrome)

            idleLine(np, size: size, onDark: panelOpen).opacity(chrome ? 0 : 1)

        }
        .frame(width: size.width, height: size.height)
        .background {
            // the cover's colours, blurred, behind the lower part
            if let np = model.nowPlaying, let art = np.artwork {
                Image(nsImage: AmbientArt.image(for: art, key: "amb\(np.artworkKey)"))
                    .resizable().scaledToFill().saturation(1.5).opacity(0.85)
                    .overlay(Color.black.opacity(0.45))
            } else { Color.black.opacity(0.6) }
        }
    }

    /// The only thing besides the cover while you are away: a thin line showing how far the song is.
    private func idleLine(_ np: NowPlayingInfo, size: CGSize, onDark: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let total = max(np.duration, 0)
            let fraction = total > 0 ? min(max(np.elapsedNow(ctx.date) / total, 0), 1) : 0
            // dark on a light cover, white on a dark one
            let light = !onDark && (np.artwork.map { ImageColor.bottomIsLight(of: $0, key: "bot\(np.artworkKey)") } ?? false)
            let ink: Color = light ? .black : .white
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(light ? 0.22 : 0.28))
                    Capsule().fill(ink.opacity(light ? 0.78 : 0.95)).frame(width: g.size.width * fraction)
                }
                .frame(height: 3)
                .shadow(color: (light ? Color.white : Color.black).opacity(0.4), radius: 2, y: 0.5)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.horizontal, 22).padding(.bottom, 16)
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
    }

    /// A small round button for the words or the list; only there when Music has them for this song.
    @ViewBuilder
    private func panelButton(_ which: Panel, symbol: String, label: String, available: Bool) -> some View {
        if available {
            let on = panel == which
            Button { withAnimation(.easeInOut(duration: 0.25)) { panel = on ? .none : which } } label: {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.62))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(on ? 0.2 : 0)))
                    .animation(.easeInOut(duration: 0.2), value: on)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).hoverLift(1.08).accessibilityLabel(label)
        } else {
            Color.clear.frame(width: 34, height: 34)
        }
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
