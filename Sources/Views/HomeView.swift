import SwiftUI
import UniformTypeIdentifiers

/// Opened by the pointer (or a file drag): the player when something is playing, otherwise the shelf.
struct HomeView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore
    let geometry: NotchGeometry
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header.rise(0)
            Group {
                switch model.homeTab {
                case .player: PlayerPane(model: model)
                case .shelf: ShelfPane(model: model, shelf: shelf)
                case .recent: RecentPane(model: model)
                }
            }
            .rise(1)
        }
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in model.dropFiles(urls) } isTargeted: { model.dropTargeted = $0 }
    }

    /// The tabs sit beside the physical notch (in the space that used to be empty), the gear on the other side.
    private var header: some View {
        let tabs = HStack(spacing: 2) {
            // three tabs do not fit with names beside the notch: then all are icons
            let compact = !model.notifications.isEmpty
            TabPill(title: "Player", symbol: "play.circle.fill", selected: model.homeTab == .player,
                    badge: model.nowPlaying?.playing == true ? Theme.green : nil, iconOnly: compact) { model.homeChoice = .player }
            TabPill(title: "Shelf", symbol: "tray.fill", selected: model.homeTab == .shelf,
                    count: shelf.items.count, iconOnly: compact) { model.homeChoice = .shelf }
            // recent notifications, once there are any; the number is the quiet ones not seen yet
            if !model.notifications.isEmpty {
                TabPill(title: "Recent", symbol: "bell.fill", selected: model.homeTab == .recent,
                        count: model.quietUnseen, iconOnly: true) { model.openRecent() }
            }
        }
        let gear = Button { openSettings() } label: { Image(systemName: "gearshape.fill") }
            .buttonStyle(RoundIconButtonStyle()).accessibilityLabel("Notch+ settings")
        // on the far side of the notch: keep awake, and the settings
        let tools = HStack(spacing: 6) {
            DesktopButton(model: model)
            CaffeineButton(model: model, caffeine: model.caffeine)
            gear
        }
        return GlassEffectContainer(spacing: 8) {
            if geometry.hasNotch {
                let side = (NotchGeometry.overviewWidth - 2 * NotchRootView.overviewSideInset - geometry.notchSize.width) / 2
                HStack(spacing: 0) {
                    tabs.frame(width: side, alignment: .leading)
                    Color.clear.frame(width: geometry.notchSize.width)
                    tools.frame(width: side, alignment: .trailing)
                }
                .frame(height: geometry.notchSize.height)
            } else {
                HStack { tabs; Spacer(); tools }.frame(height: 30)
            }
        }
    }
}

/// Hides the files on the desktop so a screen recording is clean; tap again to bring them back.
private struct DesktopButton: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let hidden = model.desktopHidden
        Button { model.setDesktopHidden(!hidden) } label: {
            Image(systemName: hidden ? "eye.slash.fill" : "eye")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hidden ? 1 : 0.85))
                .frame(width: 26, height: 26)
                .glassEffect(hidden ? .regular.tint(Theme.violet.opacity(0.7)).interactive() : .regular.interactive(), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hidden)
        .onAppear { model.refreshDesktop() }
        .help(hidden ? "Desktop files are hidden. Click to show them again." : "Hide the files on the desktop for a clean screen recording (Finder restarts for a second).")
        .accessibilityLabel("Hide desktop items").accessibilityValue(hidden ? "On" : "Off")
    }
}

/// Keeps the Mac awake. A tap switches it on or off; a right-click offers a time limit.
private struct CaffeineButton: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var caffeine: Caffeine

    var body: some View {
        let on = caffeine.active
        Button { model.setCaffeine(on ? nil : .untilOff) } label: {
            Image(systemName: on ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.white : .white.opacity(0.85))
                .frame(width: 26, height: 26)
                .glassEffect(on ? .regular.tint(Theme.amber.opacity(0.7)).interactive() : .regular.interactive(), in: Circle())
                .shadow(color: on ? Theme.amber.opacity(0.45) : .clear, radius: 7)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: on)
        .help(on ? "Keeping your Mac awake. Click to stop." : "Keep your Mac awake. Right-click for a time limit.")
        .accessibilityLabel("Keep Mac awake").accessibilityValue(on ? "On" : "Off")
        .contextMenu {
            ForEach(Caffeine.Duration.allCases) { d in
                Button(d.title) { model.setCaffeine(d) }
            }
            if on {
                Divider()
                Button("Let it sleep") { model.setCaffeine(nil) }
            }
        }
    }
}

private struct TabPill: View {
    let title: String
    let symbol: String
    let selected: Bool
    var badge: Color?
    var count: Int = 0
    var iconOnly = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                if selected, !iconOnly { Text(title).font(Theme.label(12, .semibold)) }     // only the open tab spells its name
                if let badge { Circle().fill(badge).frame(width: 6, height: 6).shadow(color: badge, radius: 3) }
                if count > 0 { Text("\(count)").font(Theme.label(10.5, .bold)).foregroundStyle(.white.opacity(0.7)) }
            }
            .foregroundStyle(selected ? .white : Theme.secondary)
            .padding(.horizontal, selected ? 10 : 8).frame(height: 26)
            .glassEffect(selected ? .regular.interactive() : .identity, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
        .animation(Motion.hover, value: selected)
    }
}

// MARK: - Player

private struct PlayerPane: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        if let np = model.nowPlaying, np.isMeaningful {
            PlayerCard(model: model, info: np)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.tertiary)
                Text("Nothing is playing").font(Theme.label(13, .semibold))
                Text("Play music or a video in any app and it shows up here, with controls.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Button { MusicLibrary.startPlaying() } label: {
                    Label("Play from Music", systemImage: "play.fill")
                        .font(Theme.label(11.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain).hoverLift(1.04).padding(.top, 4)
                .help("Opens Music and plays where you left off, or shuffles your library")
            }
            .frame(maxWidth: .infinity, minHeight: 96)
        }
    }
}

private struct PlayerCard: View {
    @ObservedObject var model: NotchModel
    let info: NowPlayingInfo
    @State private var scrubbing: Double?
    @State private var torn = false
    @State private var musicControls: MusicControls?

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        AppIconView(bundleID: info.bundleID, size: 12)
                        Text(AppLookup.name(for: info.bundleID)).font(Theme.label(10)).foregroundStyle(Theme.secondary).lineLimit(1)
                        if info.playing { EqualizerBars(color: accent).scaleEffect(0.8, anchor: .leading) }
                        Spacer(minLength: 0)
                    }
                    MarqueeText(text: info.title, font: Theme.title(15.5))
                    Text([info.artist, info.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.text(12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // previous, play, next; under them Music's own star, shuffle and repeat (only when Music answers), as tall as the cover together
                VStack(spacing: 9) {
                    controls
                    if let c = musicControls { MediaSwitches(controls: c, accent: accent, size: 26) { musicControls = $0 } }
                }
            }
            progress
        }
        // drag the card down out of the notch and it becomes the floating player, under the pointer
        .gesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                if !torn, v.translation.height > 34 { torn = true; model.tearOffPlayer() }
            }
            .onEnded { _ in torn = false })
        .help("Drag down to float this player above your windows")
        .task(id: "\(info.bundleID)|\(info.title)|\(info.artist)") {
            musicControls = info.bundleID == MusicLibrary.bundleID ? await MusicLibrary.controls() : nil
        }
    }

    private var accent: Color {
        info.artwork.map { ImageColor.dominant(of: $0, key: "art\(info.artworkKey)") } ?? Theme.violet
    }

    private var artwork: some View {
        Group {
            if let img = info.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.violet.opacity(0.6), Theme.blue.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: 66, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: accent.opacity(0.5), radius: 10, y: 3)
        .scaleEffect(info.playing ? 1 : 0.94)
        .animation(Motion.resize, value: info.playing)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let total = max(info.duration, 0)
            let now = scrubbing ?? info.elapsedNow(ctx.date)
            let fraction = total > 0 ? min(max(now / total, 0), 1) : 0
            HStack(spacing: 8) {
                Text(Elapsed.clock(now)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Theme.tertiary)
                SeekBar(fraction: fraction, accent: accent, enabled: total > 0,
                        scrub: { scrubbing = $0 * total },
                        commit: { model.seekMedia(to: $0 * total); DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scrubbing = nil } })
                Text(total > 0 ? "-" + Elapsed.clock(total - now) : "").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { model.sendMedia(.previous) } label: { Image(systemName: "backward.fill").font(.system(size: 14)) }
                .buttonStyle(.plain).hoverLift(1.12).accessibilityLabel("Previous track")
            Button { model.sendMedia(.togglePlayPause) } label: {
                Image(systemName: info.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 34, height: 34).background(Circle().fill(.white))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain).hoverLift(1.08).accessibilityLabel(info.playing ? "Pause" : "Play")
            Button { model.sendMedia(.next) } label: { Image(systemName: "forward.fill").font(.system(size: 14)) }
                .buttonStyle(.plain).hoverLift(1.12).accessibilityLabel("Next track")
        }
        .foregroundStyle(.white.opacity(0.92))
    }
}

/// Four little bars that dance while something plays.
/// Music is playing: a small wave of rounded bars that grow from the middle, taller in the centre,
/// moving smoothly and tinted from the cover (like the iPhone's island). The motion is drawn, not the real
/// sound: reading the real audio would need the Screen Recording permission.
struct EqualizerBars: View {
    let color: Color
    /// How tall each bar may get: a wave shape, highest in the middle.
    private static let envelope: [Double] = [0.45, 0.75, 1.0, 0.75, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(Self.envelope.indices, id: \.self) { i in
                    let k = Double(i)
                    // two slow waves at unrelated speeds, so it never looks like a loop
                    let wave = 0.5 + 0.3 * sin(t * (3.1 + k * 0.7) + k * 1.9) + 0.2 * sin(t * (5.3 - k * 0.4) + k * 0.8)
                    let level = Motion.reduce ? 0.7 : 0.45 + 0.55 * wave
                    Capsule()
                        .fill(LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: max(5, 18 * Self.envelope[i] * level))
                }
            }
            .frame(height: 18)
            .shadow(color: color.opacity(0.45), radius: 4)
        }
    }
}

// MARK: - Recent notifications

/// The last notifications, including the quiet ones that never opened a card. Click one to open its app.
private struct RecentPane: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(model.notifications) { n in RecentRow(note: n) { model.openSource(of: n) } }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Clear") { withAnimation(Motion.content) { model.clearRecent() } }
                    .buttonStyle(.plain).font(Theme.label(11, .semibold)).foregroundStyle(Theme.tertiary)
                    .help("Empty this list (the apps keep their notifications)")
            }
        }
    }
}

private struct RecentRow: View {
    let note: CapturedNotification
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                AppIconView(bundleID: note.bundleID, size: 22, glow: false)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(note.headline).font(Theme.label(12.5, .semibold)).foregroundStyle(.white).lineLimit(1)
                        if note.priority == .now { Chip(text: "Needs you", color: Theme.amber) }
                        Spacer(minLength: 4)
                        Text(Elapsed.ago(note.raw.date)).font(Theme.label(10)).foregroundStyle(Theme.tertiary)
                    }
                    Text(note.summary ?? note.detail ?? note.appName).font(Theme.text(11.5))
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hover ? 0.10 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .help("Open \(note.appName)")
    }
}

// MARK: - Shelf

private struct ShelfPane: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore
    var body: some View {
        if shelf.items.isEmpty { dropZone } else { tiles }
    }

    private var dropZone: some View {
        let active = model.dropTargeted || model.dragging
        return VStack(spacing: 6) {
            Image(systemName: active ? "arrow.down.circle.fill" : "tray.and.arrow.down.fill")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(active ? Theme.blue : Theme.tertiary)
                .symbolEffect(.bounce, value: active)
            Text(active ? "Let go to keep it here" : "Drop files here").font(Theme.label(13, .semibold))
            Text("Park files on the notch, then drag them into any app. Nothing is copied or moved.")
                .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(active ? Theme.blue.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(active ? Theme.blue : Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
        .animation(Motion.hover, value: active)
    }

    /// The single selected file, when exactly one is selected.
    private var single: ShelfItem? {
        guard model.selection.count == 1 else { return nil }
        return shelf.items.first { model.selection.contains($0.id) }
    }

    private var tiles: some View {
        VStack(spacing: 8) {
            FileGrid(model: model, store: shelf, columns: 6, maxHeight: 178, showsDropPlaceholder: model.dropTargeted || model.dragging)
            if let item = single {
                if model.asking == item.id, let asker = model.asker(for: item) {
                    AskPanel(model: model, asker: asker, item: item)
                        .id("ask-\(item.id)")
                        .transition(.blurFade)
                } else {
                    ShelfActionBar(model: model, shelf: shelf, item: item)
                        .id(item.id)
                        .transition(.blurFade)
                }
            } else if model.selection.count > 1 {
                FileBulkBar(model: model, store: shelf).transition(.blurFade)
            }
            HStack(spacing: 10) {
                Text("\(shelf.items.count) on the shelf  ·  ⌘-click for several")
                    .font(Theme.label(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer()
                if shelf.items.count > 1 {
                    Button("Select all") { model.selection.selectAll(shelf.items.map(\.id)) }
                        .buttonStyle(.plain).font(Theme.label(10.5, .semibold)).foregroundStyle(Theme.secondary)
                }
                Button("Clear") { shelf.clear(); model.selection.clear() }
                    .buttonStyle(.plain).font(Theme.label(10.5, .semibold)).foregroundStyle(Theme.secondary)
            }
        }
        .animation(Motion.content, value: model.selection.count)
    }
}

/// The question box for one file: a few suggested questions, the conversation so far, and a field to type in.
private struct AskPanel: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var asker: FileAsker
    let item: ShelfItem
    @State private var text = ""
    @SwiftUI.FocusState private var focused: Bool

    private var suggestions: [String] {
        switch asker.kind {
        case .image: ["What is in this picture?", "Read the text in it", "What are the numbers here?"]
        case .pdf: ["Summarize this", "What are the key dates?", "Who is it from?"]
        case .audio, .video: ["Summarize this", "What are the main points?", "List any names or dates"]
        default: ["Summarize this", "What are the main points?", "Any numbers or dates?"]
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if asker.turns.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in
                            Button { asker.ask(s) } label: {
                                Text(s).font(Theme.label(11.5, .medium)).lineLimit(1)
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .background(Capsule().fill(Color.white.opacity(0.1)))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .buttonStyle(.plain).hoverLift(1.04)
                        }
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(asker.turns) { t in turn(t).id(t.id) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .onChange(of: asker.turns.last?.answer) { _, _ in
                        if let id = asker.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.violet)
                TextField("Ask about \(item.name)", text: $text)
                    .textFieldStyle(.plain).font(Theme.text(13))
                    .focused($focused)
                    .onSubmit { send() }
                    .onKeyPress(.escape) { model.stopAsking(); return .handled }
                if asker.busy {
                    ProgressView().controlSize(.small)
                } else if !text.isEmpty {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.blue).accessibilityLabel("Send question")
                }
                if let answer = asker.lastAnswer, !asker.busy {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Copy the last answer").accessibilityLabel("Copy the last answer")
                }
                Button { model.stopAsking() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.tertiary).help("Close").accessibilityLabel("Close the question box")
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(focused ? Theme.violet.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1))
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
    }

    private func send() {
        let q = text
        text = ""
        asker.ask(q)
    }

    @ViewBuilder private func turn(_ t: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t.question).font(Theme.label(10.5, .semibold)).foregroundStyle(Theme.tertiary)
            if t.answer.isEmpty && !t.finished {
                if t.status.isEmpty { ShimmerBar(width: 200) }
                else { Text(t.status).font(Theme.label(12)).foregroundStyle(Theme.violet).lineLimit(1) }
            } else {
                Text(t.answer).font(Theme.text(13)).foregroundStyle(t.failed ? Theme.amber : .white)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What can be done with the selected file: the smart actions as bright chips, the rest under "More".
struct ShelfActionBar: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore
    let item: ShelfItem
    /// The question box lives in the notch, so the basket does not offer it.
    var allowAsk = true

    var body: some View {
        let url = shelf.url(for: item)
        HStack(spacing: 6) {
            if let job = model.job(for: item.id) {
                Image(systemName: "sparkles").foregroundStyle(Theme.violet).symbolEffect(.pulse)
                Text("\(job.verb)… \(job.fraction.map { "\(Int($0 * 100))%" } ?? job.status)")
                    .font(Theme.label(12, .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 0)
            } else if let url {
                let m = FileActions.menu(for: FileKind.of(url))
                if allowAsk, FileAsker.canAsk(FileKind.of(url)) {
                    Button { model.startAsking(item) } label: {
                        Label("Ask", systemImage: "questionmark.bubble.fill").labelStyle(.titleAndIcon)
                            .font(Theme.label(11.5, .semibold)).lineLimit(1)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11).frame(height: 28)
                            .background(Capsule().fill(LinearGradient(colors: [Theme.blue.opacity(0.75), Theme.violet.opacity(0.75)],
                                                                      startPoint: .leading, endPoint: .trailing)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain).hoverLift(1.04)
                    .help("Ask a question about this file. Answered on your Mac.")
                }
                ForEach(Array(m.intelligence.prefix(allowAsk && FileAsker.canAsk(FileKind.of(url)) ? 1 : 2))) { a in
                    Button { model.startAction(a.id, on: item) } label: {
                        Label(a.title, systemImage: a.symbol).labelStyle(.titleAndIcon)
                            .font(Theme.label(11.5, .semibold)).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Capsule().fill(Theme.violet.opacity(0.22)))
                            .overlay(Capsule().strokeBorder(Theme.violet.opacity(0.5), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain).hoverLift(1.04)
                }
                Menu {
                    ForEach(Array(m.intelligence.dropFirst(allowAsk && FileAsker.canAsk(FileKind.of(url)) ? 1 : 2))) { a in
                        Button { model.startAction(a.id, on: item) } label: { Label(a.title, systemImage: a.symbol) }
                    }
                    if !m.transcribeIn.isEmpty {
                        Menu("Transcribe in") { ForEach(m.transcribeIn) { a in Button(a.title) { model.startAction(a.id, on: item) } } }
                    }
                    if !m.translate.isEmpty {
                        LanguageMenu(title: m.translateTitle, actions: m.translate) { model.startAction($0.id, on: item) }
                    }
                    if !m.convert.isEmpty {
                        Menu("Convert") { ForEach(m.convert) { a in Button(a.title) { model.startAction(a.id, on: item) } } }
                    }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
                    Button("Remove from shelf") { shelf.remove(item.id) }
                } label: {
                    HStack(spacing: 4) {
                        Text("More").font(Theme.label(11.5, .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
                Spacer(minLength: 0)
                Text(item.name).font(Theme.label(10.5)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 130, alignment: .trailing)
            } else {
                Image(systemName: "questionmark.folder").foregroundStyle(Theme.tertiary)
                Text("This file is no longer there").font(Theme.label(12)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Button("Remove") { shelf.remove(item.id) }.buttonStyle(.plain).font(Theme.label(11.5, .semibold)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(height: 30)
    }
}

struct ShelfTile: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore
    let item: ShelfItem
    var selected = false
    var onSelect: () -> Void = {}
    @State private var over = false
    @State private var dragStarted = false

    var body: some View {
        let url = shelf.url(for: item)
        let job = model.job(for: item.id)
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = shelf.thumbnails[item.id] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "doc.fill").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.gray)
                    }
                }
                .frame(width: 56, height: 56)
                .opacity(url == nil ? 0.35 : (job == nil ? 1 : 0.45))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.white.opacity(0.12) : Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.violet.opacity(0.9) : .clear, lineWidth: 1.6))
                .shadow(color: selected ? Theme.violet.opacity(0.45) : .clear, radius: 7)
                .overlay { if let job { ProgressRing(fraction: job.fraction) } }
                if over, job == nil {
                    Button { shelf.remove(item.id) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                        .buttonStyle(.plain).foregroundStyle(.white, .black.opacity(0.7)).offset(x: 5, y: -5).accessibilityLabel("Remove \(item.name) from the shelf")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            Text(job.map { $0.fraction.map { "\(Int($0 * 100))%" } ?? $0.verb } ?? item.name)
                .font(Theme.label(10)).foregroundStyle(job != nil ? Theme.violet : (url == nil ? Theme.tertiary : Theme.secondary))
                .lineLimit(1).truncationMode(.middle).frame(width: 66)
        }
        .scaleEffect(over ? 1.05 : 1)
        .onHover { h in withAnimation(Motion.hover) { over = h } }
        .onAppear { shelf.loadThumbnail(for: item) }
        .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name).accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show actions") { onSelect() }
        .accessibilityAction(named: "Open") { if let url { NSWorkspace.shared.open(url) } }
        .onDrag { dragStarted = true; return url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .onDragSessionUpdated { session in
            guard dragStarted else { return }
            switch session.phase {
            case .ended(let op):
                dragStarted = false
                model.dragOutEnded(item.id, droppedSomewhere: op == .copy || op == .move || op == .alias)
            default: break
            }
        }
        .contextMenu { menu(url) }
        .help(job.map { $0.verb + "… " + $0.status } ?? url?.path ?? "This file is no longer there")
    }

    @ViewBuilder private func menu(_ url: URL?) -> some View {
        if let url, model.job(for: item.id) == nil {
            let m = FileActions.menu(for: FileKind.of(url))
            if !m.isEmpty {
                Menu {
                    ForEach(m.intelligence) { a in
                        Button { model.startAction(a.id, on: item) } label: { Label(a.title, systemImage: a.symbol) }
                    }
                    if !m.transcribeIn.isEmpty {
                        Menu("Transcribe in") {
                            ForEach(m.transcribeIn) { a in Button(a.title) { model.startAction(a.id, on: item) } }
                        }
                    }
                    if !m.translate.isEmpty {
                        LanguageMenu(title: m.translateTitle, actions: m.translate) { model.startAction($0.id, on: item) }
                    }
                } label: { Label("Apple Intelligence", systemImage: "sparkles") }
                if !m.convert.isEmpty {
                    Menu {
                        ForEach(m.convert) { a in Button(a.title) { model.startAction(a.id, on: item) } }
                    } label: { Label("Convert", systemImage: "arrow.triangle.2.circlepath") }
                }
                Divider()
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
        } else if let job = model.job(for: item.id) {
            Text(job.verb + "… " + job.status)
        }
        Button("Remove from shelf") { shelf.remove(item.id) }
    }
}

/// A ring that fills as an action runs (spins when the progress is not known yet).
struct ProgressRing: View {
    let fraction: Double?
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
            if let f = fraction {
                Circle().trim(from: 0, to: max(0.03, f))
                    .stroke(Theme.violet, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.resize, value: f)
            } else {
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Theme.violet, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true } }
            }
        }
        .frame(width: 30, height: 30)
        .shadow(color: Theme.violet.opacity(0.6), radius: 4)
    }
}
