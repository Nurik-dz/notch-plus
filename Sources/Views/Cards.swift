import SwiftUI

// MARK: - A notification from another app

struct NotificationCard: View {
    @ObservedObject var model: NotchModel
    let geometry: NotchGeometry
    let notification: CapturedNotification

    private var accent: Color { AppLookup.accent(for: notification.bundleID) }

    var body: some View {
        VStack(spacing: 9) {
            // beside the notch: which app on the left, how much it matters on the right
            BesideNotch(geometry: geometry, cardWidth: NotchGeometry.notificationWidth) {
                AppIconView(bundleID: notification.bundleID, size: 18, glow: true)
                Text(notification.appName.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.6)
                    .foregroundStyle(Theme.secondary)
            } trailing: {
                if notification.priority == .now || notification.priority == .noise {
                    priority
                } else {
                    Text("now").font(Theme.label(10)).foregroundStyle(Theme.tertiary)
                }
                if model.toastsWaiting > 0 {
                    // more notifications are waiting behind this one
                    Text("+\(model.toastsWaiting)").font(Theme.label(10.5, .bold)).foregroundStyle(Theme.blue)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.blue.opacity(0.18)))
                        .contentTransition(.numericText(value: Double(model.toastsWaiting)))
                        .accessibilityLabel("\(model.toastsWaiting) more waiting")
                }
            }
            .rise(0)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.headline).font(Theme.title(15)).lineLimit(1)
                    detailLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .rise(1)
                VStack(spacing: 5) {
                    Button { model.dismissToast() } label: { Image(systemName: "xmark") }
                        .buttonStyle(RoundIconButtonStyle()).help("Dismiss").accessibilityLabel("Dismiss notification")
                    Button { model.muteSource(of: notification) } label: { Image(systemName: "bell.slash.fill") }
                        .buttonStyle(RoundIconButtonStyle()).help("Keep \(notification.appName) quiet from now on").accessibilityLabel("Keep \(notification.appName) quiet")
                }
                .rise(2)
            }
            if isReplying {
                ReplyBox(model: model, accent: accent)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else {
                if model.canReply(notification) {
                    HStack {
                        Button { model.startReply(notification) } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                        }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .help("Answer from here; nothing is sent until you press Send")
                        Spacer(minLength: 0)
                    }
                    .rise(3)
                }
                TimerBar(color: accent, seconds: 6).id(notification.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if !isReplying { model.openSource(of: notification) } }
        .animation(Motion.resize, value: isReplying)
    }

    private var isReplying: Bool { model.replying == notification.id }

    @ViewBuilder private var priority: some View {
        switch notification.priority {
        case .now: Chip(text: "Needs you", symbol: "bolt.fill", color: Theme.amber, compact: model.toastsWaiting > 0)
        case .later: EmptyView()
        case .noise: Chip(text: "Quiet", symbol: "moon.fill", color: .gray, compact: model.toastsWaiting > 0)
        case nil: EmptyView()
        }
    }

    /// The summary only exists when "Short summary" is chosen in Settings, and only replaces a message too
    /// long to read at a glance; short ones stay word for word. While replying, always the full message.
    private var showsSummary: Bool {
        !isReplying && notification.summary != nil && (notification.detail?.count ?? 0) >= NotchModel.summaryMinLength
    }

    @ViewBuilder private var detailLine: some View {
        ZStack(alignment: .topLeading) {
            if showsSummary, let s = notification.summary {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.violet)
                    Text(s).font(Theme.text(12)).foregroundStyle(.white.opacity(0.82)).lineLimit(2)
                }
                .transition(.blurFade)
            } else if let d = notification.detail {
                Text(d).font(Theme.text(12)).foregroundStyle(.white.opacity(0.78)).lineLimit(isReplying ? 5 : 2)
                    .transition(.blurFade)
            }
        }
        .animation(.smooth(duration: 0.45), value: showsSummary)
    }
}

/// Typing a reply on a Messages card: three suggestions to start from (tap one to put it in the field,
/// never sent by itself), the field, and Send. Return sends, Escape closes.
private struct ReplyBox: View {
    @ObservedObject var model: NotchModel
    let accent: Color
    @State private var text = ""
    @SwiftUI.FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.replySuggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.replySuggestions, id: \.self) { s in
                        Button { text = s; focused = true } label: { ChipLabel(title: s) }
                        .buttonStyle(.plain)
                        .help("Put this in the reply field")
                    }
                }
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 11)).foregroundStyle(accent)
                TextField("Reply", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.text(13)).lineLimit(1...3)
                    .focused($focused)
                    .onSubmit { model.sendReply(text) }
                    .onKeyPress(.escape) { model.dismissToast(); return .handled }
                if model.replySending {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.sendReply(text) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain).foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.tertiary : accent)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Send").accessibilityLabel("Send reply")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(focused ? accent.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1))
            if let e = model.replyError {
                Text(e).font(Theme.text(11.5)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.content, value: model.replySuggestions)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
    }
}

// MARK: - Claude finished a long task

struct FinishedCard: View {
    @ObservedObject var model: NotchModel
    let geometry: NotchGeometry
    let finish: ClaudeFinish

    var body: some View {
        VStack(spacing: 9) {
            // beside the notch: a green tick and "Finished" on the left, how long it took on the right
            BesideNotch(geometry: geometry, cardWidth: NotchGeometry.finishedWidth) {
                ZStack {
                    Circle().fill(Theme.green.opacity(0.2)).frame(width: 18, height: 18)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.green)
                }
                .shadow(color: Theme.green.opacity(0.6), radius: 6)
                Text("FINISHED")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.6).foregroundStyle(Theme.green)
            } trailing: {
                if let d = finish.duration { Text("in " + Elapsed.words(d)).font(Theme.label(10)).foregroundStyle(Theme.tertiary) }
            }
            .rise(0)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(finish.project).font(Theme.title(15)).lineLimit(1)
                        if let b = finish.branch {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5)).foregroundStyle(Theme.secondary)
                            Text(b).font(Theme.label(11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                    if let m = finish.message {
                        Text(m).font(Theme.text(12)).foregroundStyle(.white.opacity(0.78)).lineLimit(2)
                    }
                }
                .rise(1)
                Spacer(minLength: 2)
                Button { model.dismissFinished() } label: { Image(systemName: "xmark") }
                    .buttonStyle(RoundIconButtonStyle()).accessibilityLabel("Dismiss")
                    .rise(2)
            }
            if let t = finish.terminal {
                HStack {
                    Button { model.goToTerminal(finish) } label: {
                        Label("Go to terminal", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .help("Bring Claude's tab in \(t.appName) to the front")
                    Spacer(minLength: 0)
                }
                .rise(3)
            }
            TimerBar(color: Theme.green, seconds: 7).id(finish.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.dismissFinished() }
    }
}

// MARK: - The music drop

/// Music that keeps playing while Claude or something else has the notch: a small black drop beside the
/// island with the cover inside and a ring that fills as the track plays.
struct MusicDrop: View {
    let info: NowPlayingInfo
    let size: CGFloat

    var body: some View {
        let accent = info.artwork.map { ImageColor.dominant(of: $0, key: "art\(info.artworkKey)") } ?? Theme.violet
        ZStack {
            Circle().fill(Color.black)
            Group {
                if let a = info.artwork {
                    Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [Theme.violet, Theme.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: size - 9, height: size - 9)
            .clipShape(Circle())
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let progress = info.duration > 0 ? min(max(info.elapsedNow(ctx.date) / info.duration, 0), 1) : 0
                Circle().trim(from: 0, to: progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.5)
                    .animation(.linear(duration: 1), value: progress)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: accent.opacity(0.45), radius: 5)
        .accessibilityElement()
        .accessibilityLabel("Playing \(info.title)")
    }
}

// MARK: - Beside the notch

/// The notch widened with a short status on each side. The middle is the physical notch and stays empty.
struct WingsView: View {
    @ObservedObject var model: NotchModel
    let geometry: NotchGeometry
    let wing: CGFloat

    private var notchGap: CGFloat { geometry.hasNotch ? geometry.notchSize.width : 0 }

    var body: some View {
        if let h = model.hud {
            hudWings(h)
        } else if let f = model.flash {
            flashWings(f)
        } else if let s = model.liveSession {
            liveWings(s)
        } else if let job = model.jobs.last {
            jobWings(job)
        } else if model.musicWingsOn, let np = model.nowPlaying {
            musicWings(np)
        } else {
            Color.clear
        }
    }

    // Volume or brightness: the symbol on the left, a level bar and the number on the right.
    private func hudWings(_ h: HUDReading) -> some View {
        let color: Color = h.kind == .volume ? (h.muted ? Theme.red : .white) : Theme.amber
        let icon = Image(systemName: h.symbol)
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .shadow(color: color.opacity(0.5), radius: 5)
        let bar = HStack(spacing: 6) {
            LevelBar(level: h.muted ? 0 : h.level, color: color)
                .frame(width: geometry.hasNotch ? 38 : 90, height: 5)
            Text("\(h.percent)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                .contentTransition(.numericText(value: Double(h.percent)))
                .frame(width: 22, alignment: .trailing)
        }
        return HStack(spacing: 0) {
            icon.frame(width: geometry.hasNotch ? wing : 44)
            if geometry.hasNotch { Color.clear.frame(width: notchGap) } else { Spacer(minLength: 0) }
            bar.frame(width: geometry.hasNotch ? wing : nil, alignment: .center)
            if !geometry.hasNotch { Spacer(minLength: 6) }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .animation(.smooth(duration: 0.16), value: h)
    }

    // After you answer a request: a tick or a cross on the left, the word on the right.
    private func flashWings(_ f: NotchModel.Flash) -> some View {
        let color = f.good ? Theme.green : Theme.red
        let symbol = Image(systemName: f.symbol).font(.system(size: 14, weight: .heavy)).foregroundStyle(color)
            .shadow(color: color.opacity(0.9), radius: 6)
        let icon = symbol
        let word = Text(f.text).font(Theme.label(12.5, .semibold)).foregroundStyle(.white).lineLimit(1)
        return HStack(spacing: 0) {
            icon.frame(width: geometry.hasNotch ? wing : 44)
            if geometry.hasNotch { Color.clear.frame(width: notchGap) } else { word; Spacer(minLength: 0) }
            if geometry.hasNotch { word.frame(width: wing, alignment: .leading).padding(.leading, 4) }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    // While Claude works: a spinner and the project on the left, what it is doing and for how long on the right.
    private func liveWings(_ s: ClaudeSession) -> some View {
        let start = s.turnStart ?? s.lastEvent
        let tool = ClaudeSession.shortTool(s.tool)
        // Just the spinner, unless two sessions are working and you need to know which this is.
        let left = HStack(spacing: 6) {
            ClaudeSpinner(size: 13)
            if model.liveCount > 1 {
                Text(s.project).font(Theme.label(10.5, .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
        }
        let right = HStack(spacing: 5) {
            Text(tool).font(Theme.label(10, .semibold)).foregroundStyle(Theme.claude).lineLimit(1).fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Theme.claude.opacity(0.16)))
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Elapsed.clock(ctx.date.timeIntervalSince(start)))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).fixedSize()
            }
        }
        return HStack(spacing: 0) {
            if geometry.hasNotch {
                left.frame(width: wing, alignment: .center).padding(.leading, 4)
                Color.clear.frame(width: notchGap)
                right.frame(width: wing, alignment: .center).padding(.trailing, 4)
            } else {
                left
                Spacer(minLength: 8)
                right
            }
        }
        .padding(.horizontal, geometry.hasNotch ? 6 : 14)
        .frame(maxHeight: .infinity)
        .minimumScaleFactor(0.8)
    }

    // While a file action runs: a sparkle on the left, the verb and the percentage on the right.
    private func jobWings(_ job: NotchModel.Job) -> some View {
        let sparkle = Image(systemName: "sparkles").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.violet)
            .shadow(color: Theme.violet.opacity(0.8), radius: 5).symbolEffect(.pulse)
        let spark = sparkle
        let info = Text(job.fraction.map { "\(Int($0 * 100))%" } ?? "…")
            .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.92))
        return HStack(spacing: 0) {
            spark.frame(width: geometry.hasNotch ? wing : 40)
            if geometry.hasNotch { Color.clear.frame(width: notchGap) } else { Text(job.fileName).font(Theme.label(11, .semibold)).lineLimit(1).truncationMode(.middle).foregroundStyle(.white.opacity(0.9)); Spacer(minLength: 6) }
            info.frame(width: geometry.hasNotch ? wing : nil, alignment: .center)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    // While music plays: the cover on the left, dancing bars on the right.
    private func musicWings(_ np: NowPlayingInfo) -> AnyView {
        let accent = np.artwork.map { ImageColor.dominant(of: $0, key: "art\(np.artworkKey)") } ?? Theme.violet
        let cover = Group {
            if let a = np.artwork {
                Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.violet, Theme.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: accent.opacity(0.6), radius: 5)
        if let peek = model.songPeek, geometry.hasNotch {
            // the song just changed: its title and artist beside the notch for a moment
            return AnyView(HStack(spacing: 0) {
                HStack(spacing: 8) {
                    cover
                    Text(peek.title).font(Theme.label(11.5, .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                .padding(.leading, 12).padding(.trailing, 8)
                .frame(width: wing, alignment: .leading)
                Color.clear.frame(width: notchGap)
                HStack(spacing: 8) {
                    Text(peek.artist).font(Theme.label(11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Spacer(minLength: 0)
                    EqualizerBars(color: accent).frame(width: 26)
                }
                .padding(.leading, 8).padding(.trailing, 12)
                .frame(width: wing, alignment: .leading)
            }
            .frame(maxHeight: .infinity))
        }
        return AnyView(HStack(spacing: 0) {
            cover.frame(width: geometry.hasNotch ? wing : 40)
            if geometry.hasNotch { Color.clear.frame(width: notchGap) } else {
                Text(np.title).font(Theme.label(11.5, .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 6)
            }
            EqualizerBars(color: accent).frame(width: geometry.hasNotch ? wing : 30)
        }
        .padding(.horizontal, geometry.hasNotch ? 0 : 4)     // on a notch the wings are exact: even space round the cover and the wave
        .frame(maxHeight: .infinity))
    }
}
