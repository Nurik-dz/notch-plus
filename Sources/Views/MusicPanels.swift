import SwiftUI

/// The words of the song, the line being sung large and white, following the music. Plain lyrics just scroll.
struct LyricsView: View {
    let lines: [LyricLine]
    let now: () -> Double
    let accent: Color
    /// Where the sung line rests, from the top (0.5 is the middle). It glides when this changes.
    var anchorY: CGFloat = 0.5
    /// Where the words fade out at the bottom, as a fraction of the height (1 = at the very bottom; less leaves room for the controls).
    var fadeAt: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            let current = LyricsParser.current(in: lines, at: now())
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(lines.indices, id: \.self) { i in
                            let sung = current == nil || i == current
                            // one font size for every line: the sung line is only scaled up and brightened, so the words never re-wrap or ghost
                            Text(lines[i].text)
                                .font(Theme.title(19))
                                .foregroundStyle(Color.white)
                                .opacity(sung ? 1 : 0.38)
                                .scaleEffect(sung || current == nil ? 1 : 0.86, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                                .animation(.easeInOut(duration: 0.35), value: current)
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 190)
                }
                .onChange(of: current) { _, c in
                    guard let c else { return }
                    withAnimation(Motion.resize) { proxy.scrollTo(c, anchor: UnitPoint(x: 0.5, y: anchorY)) }
                }
                .onChange(of: anchorY) { _, y in
                    guard let current else { return }
                    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: y)) }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: anchorY)) } }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                                     .init(color: .black, location: max(0.2, fadeAt - 0.14)), .init(color: .clear, location: fadeAt),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .animation(.easeInOut(duration: 0.4), value: fadeAt)
    }
}

/// The album or playlist that is playing, like Music's own list: a cover, the title and the artist on every row.
/// The song now playing sits in a bright pill with a moving waveform on its cover; a click plays another song.
struct TrackListView: View {
    let tracks: [AlbumTrack]
    let currentID: String
    let accent: Color
    var isPlaying = true
    /// The cover of the album, shown small on every row when all songs are from that one album.
    var cover: NSImage?
    var anchorY: CGFloat = 0.5
    var fadeAt: CGFloat = 1
    let play: (AlbumTrack) -> Void

    /// Worked out once per draw of the list, never per row.
    private var showCovers: Bool { cover != nil && Set(tracks.map(\.album)).count == 1 }

    var body: some View {
        let covers = showCovers
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 3) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { n, t in
                        row(n, t, now: t.id == currentID, covers: covers).id(t.id)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 190)
            }
            .onAppear { proxy.scrollTo(currentID, anchor: UnitPoint(x: 0.5, y: anchorY)) }
            .onChange(of: anchorY) { _, y in
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(currentID, anchor: UnitPoint(x: 0.5, y: y)) }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                                     .init(color: .black, location: max(0.2, fadeAt - 0.14)), .init(color: .clear, location: fadeAt),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .animation(.easeInOut(duration: 0.4), value: fadeAt)
    }

    private func row(_ n: Int, _ t: AlbumTrack, now: Bool, covers: Bool) -> some View {
        Button { play(t) } label: {
            HStack(spacing: 11) {
                lead(n, now: now, covers: covers)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).font(Theme.label(now ? 15 : 14, now ? .bold : .semibold))
                        .foregroundStyle(now ? Color.white : Color.white.opacity(0.85)).lineLimit(1)
                    if !t.artist.isEmpty {
                        Text(t.artist).font(Theme.text(11.5)).foregroundStyle(now ? Color.white.opacity(0.8) : Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(Elapsed.clock(t.duration)).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(now ? Color.white.opacity(0.75) : Theme.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background {
                if now {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.32), lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The small cover (with the waveform on it for the playing song), or just the number.
    @ViewBuilder
    private func lead(_ n: Int, now: Bool, covers: Bool) -> some View {
        if covers, let cover {
            Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 38)
                .overlay { if now { Color.black.opacity(0.45) } }
                .overlay {
                    if now {
                        MiniWave(playing: isPlaying, size: 15)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Group {
                if now {
                    MiniWave(playing: isPlaying, size: 15)
                } else { Text("\(n + 1)").foregroundStyle(Theme.tertiary) }
            }
            .font(now ? Theme.label(15, .bold) : Theme.label(12)).frame(width: 38, height: 38)
        }
    }
}

/// Favourite, shuffle and repeat: bare icons, no circles; the one that is on gets a soft pill behind it.
/// `update` receives the new state at once (so the button answers before Music does); Music is then told.
/// Used by the floating player and the notch card (`size` sets the touch area).
struct MediaSwitches: View {
    let controls: MusicControls
    let accent: Color
    var size: CGFloat = 28
    let update: (MusicControls) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button(controls.favorited ? "star.fill" : "star", on: controls.favorited,
                   label: controls.favorited ? "Remove from favourites" : "Favourite") {
                var c = controls; c.favorited.toggle(); update(c); MusicLibrary.setFavorite(c.favorited)
            }
            button("shuffle", on: controls.shuffle, label: controls.shuffle ? "Shuffle is on" : "Shuffle") {
                var c = controls; c.shuffle.toggle(); update(c); MusicLibrary.setShuffle(c.shuffle)
            }
            button(controls.repeatMode == .one ? "repeat.1" : "repeat", on: controls.repeatMode != .off,
                   label: controls.repeatMode == .off ? "Repeat" : (controls.repeatMode == .all ? "Repeat all" : "Repeat this song")) {
                var c = controls; c.repeatMode = c.repeatMode.next; update(c); MusicLibrary.setRepeat(c.repeatMode)
            }
        }
    }

    private func button(_ symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.62))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(on ? 0.2 : 0)))
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.2), value: on)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).hoverLift(1.08).accessibilityLabel(label)
    }
}

/// The little moving bars on the song that is playing. Drawn in one small canvas ten times a second: the system's
/// animated waveform symbol redraws far more often, and under the faded list that meant redrawing the whole list.
struct MiniWave: View {
    let playing: Bool
    var size: CGFloat = 15
    private static let heights: [Double] = [0.55, 1.0, 0.7, 0.9, 0.5]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, canvas in
                let n = Self.heights.count
                let gap = canvas.width * 0.09
                let w = (canvas.width - gap * CGFloat(n - 1)) / CGFloat(n)
                for i in 0..<n {
                    let k = Double(i)
                    let wave = playing && !Motion.reduce ? 0.5 + 0.5 * sin(t * (4.1 + k * 0.9) + k * 1.7) : 0.7
                    let h = max(w, canvas.height * Self.heights[i] * (0.35 + 0.65 * wave))
                    let r = CGRect(x: CGFloat(i) * (w + gap), y: (canvas.height - h) / 2, width: w, height: h)
                    g.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(.white))
                }
            }
        }
        .frame(width: size, height: size)
    }
}
