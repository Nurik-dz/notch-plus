import SwiftUI

// MARK: - A notification from another app

struct NotificationCard: View {
    @ObservedObject var model: NotchModel
    let notification: CapturedNotification

    private var accent: Color { AppLookup.accent(for: notification.bundleID) }

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                AppIconView(bundleID: notification.bundleID, size: 40, glow: true).rise(0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(notification.appName.uppercased())
                            .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.6)
                            .foregroundStyle(Theme.secondary).lineLimit(1)
                        Text("now").font(Theme.label(9.5)).foregroundStyle(Theme.tertiary)
                        Spacer(minLength: 4)
                        priority
                    }
                    Text(notification.headline).font(Theme.title(14)).lineLimit(1)
                    detailLine
                }
                .rise(1)
                VStack(spacing: 5) {
                    Button { model.dismissToast() } label: { Image(systemName: "xmark") }
                        .buttonStyle(RoundIconButtonStyle()).help("Dismiss").accessibilityLabel("Dismiss notification")
                    Button { model.muteSource(of: notification) } label: { Image(systemName: "bell.slash.fill") }
                        .buttonStyle(RoundIconButtonStyle()).help("Keep \(notification.appName) quiet from now on").accessibilityLabel("Keep \(notification.appName) quiet")
                }
                .rise(2)
            }
            TimerBar(color: accent, seconds: 6).id(notification.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.openSource(of: notification) }
    }

    @ViewBuilder private var priority: some View {
        switch notification.priority {
        case .now: Chip(text: "Needs you", symbol: "bolt.fill", color: Theme.amber)
        case .later: EmptyView()
        case .noise: Chip(text: "Quiet", symbol: "moon.fill", color: .gray)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private var detailLine: some View {
        if let s = notification.summary, (notification.detail?.count ?? 0) > 90 {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.violet)
                Text(s).font(Theme.text(12)).foregroundStyle(.white.opacity(0.82)).lineLimit(2)
            }
        } else if let d = notification.detail {
            Text(d).font(Theme.text(12)).foregroundStyle(.white.opacity(0.78)).lineLimit(2)
        }
    }
}

// MARK: - Claude finished a long task

struct FinishedCard: View {
    @ObservedObject var model: NotchModel
    let finish: ClaudeFinish

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.green.opacity(0.18)).frame(width: 38, height: 38)
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.green)
                }
                .shadow(color: Theme.green.opacity(0.5), radius: 9)
                .rise(0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("CLAUDE FINISHED")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.6).foregroundStyle(Theme.green)
                        if let d = finish.duration { Text("in " + Elapsed.words(d)).font(Theme.label(9.5)).foregroundStyle(Theme.tertiary) }
                    }
                    HStack(spacing: 5) {
                        Text(finish.project).font(Theme.title(14)).lineLimit(1)
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
            TimerBar(color: Theme.green, seconds: 7).id(finish.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.dismissFinished() }
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
                .frame(width: geometry.hasNotch ? 46 : 90, height: 5)
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
    private func musicWings(_ np: NowPlayingInfo) -> some View {
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
        return HStack(spacing: 0) {
            cover.frame(width: geometry.hasNotch ? wing : 40)
            if geometry.hasNotch { Color.clear.frame(width: notchGap) } else {
                Text(np.title).font(Theme.label(11.5, .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 6)
            }
            EqualizerBars(color: accent).frame(width: geometry.hasNotch ? wing : 30)
        }
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
    }
}
