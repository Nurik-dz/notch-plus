import SwiftUI

/// A small squash and stretch each time the island changes state: opening pulls it down a touch and
/// squeezes it in, then it settles; closing does the reverse. Hangs from the top edge like a drop.
private struct Jelly: ViewModifier {
    struct Value { var x = 1.0, y = 1.0 }
    let trigger: IslandState
    let open: Bool

    func body(content: Content) -> some View {
        if Motion.reduce {
            content
        } else {
            content.keyframeAnimator(initialValue: Value(), trigger: trigger) { view, v in
                view.scaleEffect(x: v.x, y: v.y, anchor: .top)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    CubicKeyframe(open ? 1.035 : 0.985, duration: 0.14)
                    SpringKeyframe(1.0, duration: 0.55, spring: .init(response: 0.35, dampingRatio: 0.55))
                }
                KeyframeTrack(\.x) {
                    CubicKeyframe(open ? 0.988 : 1.0, duration: 0.14)
                    SpringKeyframe(1.0, duration: 0.55, spring: .init(response: 0.35, dampingRatio: 0.55))
                }
            }
        }
    }
}

/// The island: a black shape that grows out of the notch, lit from above, sized to its content,
/// with the card for the current state inside.
struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    let geometry: NotchGeometry
    let openSettings: () -> Void

    /// How far the top corners flare out into the screen edge (closed / open).
    static let flareClosed: CGFloat = 6
    static let flareOpen: CGFloat = 14
    /// Side space of the overview card (clears the flared top corners).
    static let overviewSideInset: CGFloat = 24

    /// The colour of the soft light behind the card.
    private var accent: Color {
        switch model.state {
        case .approval:
            switch model.current?.request.risk {
            case .high: Theme.red
            case .medium: Theme.amber
            default: Theme.green
            }
        case .notification: model.toast.map { AppLookup.accent(for: $0.bundleID) } ?? Theme.blue
        case .finished: Theme.green
        case .result:
            if case .failed = model.outcome { Theme.red } else { Theme.green }
        case .wings: model.flash.map { $0.good ? Theme.green : Theme.red } ?? Theme.claude
        case .overview:
            if model.homeTab == .player, let art = model.nowPlaying?.artwork { ImageColor.dominant(of: art, key: "art\(model.nowPlaying?.artworkKey ?? 0)") }
            else if model.homeTab == .player { Theme.violet } else { Theme.blue }
        case .closed: .clear
        }
    }

    /// Changes when a different card takes over (so the old one blurs out and the new one sharpens in).
    private var contentID: AnyHashable {
        switch model.state {
        case .approval: AnyHashable(model.current?.request.id)
        case .notification: AnyHashable(model.toast?.id)
        case .finished: AnyHashable(model.finished?.id)
        case .result: AnyHashable(model.outcomeStamp)
        default: AnyHashable(model.state)
        }
    }

    var body: some View {
        let state = model.state
        let open = model.isOpen
        let rim = open || state == .wings
        let wingW = model.wingsWidth
        let size = geometry.shapeSize(state, height: model.contentHeights[state], anticipating: model.anticipating, wing: wingW)
        let flare = open ? Self.flareOpen : Self.flareClosed
        let shape = NotchShape(topRadius: flare, bottomRadius: open ? 32 : 14)
        let light = accent
        // the living edge light: full on open cards, gentle while Claude or a file action is working, off otherwise
        let glow: Double = (open ? 1 : ((state == .wings && (model.liveSession != nil || !model.jobs.isEmpty)) ? 0.55 : 0)) * model.glowLevel.factor * (Motion.lessTransparency ? 0.35 : 1)
        // black like the hardware notch unless Liquid Glass is chosen in Settings
        let glassy = open && model.islandStyle == .glass && !Motion.lessTransparency
        let bubble = model.musicBubble
        let bubbleX = bubble ? size.width / 2 - flare + Self.bubbleGap + Self.bubbleSize / 2
                             : size.width / 2 - flare - Self.bubbleSize / 2 - 2
        let bubbleY = (size.height - Self.bubbleSize) / 2

        ZStack(alignment: .top) {
            // the liquid layer: joins the island and the music drop with a neck while they are close
            if state == .wings {
                GooLayer(width: size.width - 2 * flare, height: size.height, radius: 14,
                         dropX: bubbleX, dropY: bubbleY, dropSize: bubble ? Self.bubbleSize : Self.bubbleSize * 0.5)
                    .allowsHitTesting(false)
            }
            island(state: state, open: open, glassy: glassy, size: size, shape: shape, light: light, glow: glow, rim: rim)
            if state == .wings, let np = model.nowPlaying {
                MusicDrop(info: np, size: Self.bubbleSize)
                    .scaleEffect(bubble ? 1 : 0.5)
                    .opacity(bubble ? 1 : 0)
                    .offset(x: bubbleX, y: bubbleY)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.spring(for: state), value: size)
        .animation(Motion.drop, value: bubble)
        .animation(.smooth(duration: 0.7), value: light)
        .environment(\.colorScheme, .dark)
    }

    /// Size of the music drop beside the island, and the gap it keeps once it has split off.
    static let bubbleSize: CGFloat = 26
    static let bubbleGap: CGFloat = 12

    @ViewBuilder
    private func island(state: IslandState, open: Bool, glassy: Bool, size: CGSize, shape: NotchShape,
                        light: Color, glow: Double, rim: Bool) -> some View {
        ZStack(alignment: .top) {
            // black body with a soft coloured light falling from the top
            ZStack {
                // solid black like the hardware notch; with Liquid Glass chosen, the open island is
                // real glass tinted by the card's colour
                shape.fill(Color.black).opacity(glassy ? 0 : 1)
                if glassy {
                    Color.clear
                        .glassEffect(.regular.tint(light.opacity(0.16)), in: shape)
                        .transition(.opacity)
                    // black at the very top so the glass melts into the hardware notch
                    shape.fill(LinearGradient(stops: [.init(color: .black, location: 0),
                                                      .init(color: .black, location: 0.08),
                                                      .init(color: .clear, location: 0.30)],
                                              startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
                // the cover, blurred into the background like a glow (only while the player is open)
                if state == .overview, model.homeTab == .player, !Motion.lessTransparency, let art = model.nowPlaying?.artwork {
                    Image(nsImage: AmbientArt.image(for: art, key: "amb\(model.nowPlaying?.artworkKey ?? 0)"))
                        .resizable().interpolation(.high).scaledToFill()
                        .frame(width: geometry.width(.overview), height: 220)
                        .saturation(1.35).opacity(0.38)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.0), .init(color: .clear, location: 0.12),
                                                     .init(color: .black, location: 0.7)], startPoint: .top, endPoint: .bottom))
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .clipShape(shape)
                        .transition(.opacity)
                }
            }

            ZStack(alignment: .top) {
                card(for: state, size: size)
                    .id(contentID)
                    .transition(.blurFade)
            }
            .animation(Motion.content, value: contentID)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .overlay {
            // a thin highlight on the upper edge, and the card's colour glowing along the lower rim
            ZStack {
                shape.stroke(LinearGradient(stops: [.init(color: .clear, location: 0.0),
                                                    .init(color: .white.opacity(glow > 0.5 ? 0.08 : (rim ? 0.24 : 0.10)), location: 0.28),
                                                    .init(color: .white.opacity(0.03), location: 1.0)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
                GlowRim(shape: shape, accent: light, strength: glow)
                // Claude has waited long: a soft amber ring swells and fades, the colour of the amber timer
                ZStack {
                    shape.stroke(Theme.amber, lineWidth: 9).blur(radius: 8).opacity(0.75)
                    shape.stroke(Theme.amber, lineWidth: 2)
                }
                .opacity(open && model.pulsing ? 1 : 0)
                .animation(.easeInOut(duration: 1.1), value: model.pulsing)
            }
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 8, y: 3)          // tight contact shadow
        .modifier(Jelly(trigger: state, open: open))
    }

    // MARK: - The cards

    /// Lays a card out at its final width, measures its natural height, and reports it,
    /// so the island can grow or shrink to hug it. The growing shape reveals the card.
    @ViewBuilder
    private func card(for state: IslandState, size: CGSize) -> some View {
        let width = geometry.width(state)
        let inset = geometry.cardTopInset
        let side = NotchGeometry.cardSideInset
        switch state {
        case .closed:
            Color.clear
        case .wings:
            WingsView(model: model, geometry: geometry, wing: model.wingsWidth)
                .frame(width: width, height: size.height)
        case .notification:
            if let n = model.toast {
                measured(state, width: width) {
                    NotificationCard(model: model, geometry: geometry, notification: n)
                        .padding(.top, inset).padding(.horizontal, side).padding(.bottom, 18)
                }
            }
        case .finished:
            if let f = model.finished {
                measured(state, width: width) {
                    FinishedCard(model: model, geometry: geometry, finish: f)
                        .padding(.top, inset).padding(.horizontal, side).padding(.bottom, 18)
                }
            }
        case .result:
            if let o = model.outcome {
                measured(state, width: width) {
                    ResultCard(model: model, geometry: geometry, outcome: o)
                        .padding(.top, inset).padding(.horizontal, side).padding(.bottom, 18)
                }
            }
        case .overview:
            measured(state, width: width) {
                HomeView(model: model, shelf: model.shelf, geometry: geometry, openSettings: openSettings)
                    .padding(.top, geometry.hasNotch ? 0 : 8).padding(.horizontal, Self.overviewSideInset)
            }
        case .approval:
            if let item = model.current {
                measured(state, width: width) {
                    Group {
                        if item.request.isQuestion {
                            QuestionCard(model: model, geometry: geometry, request: item.request, queued: model.pending.count)
                        } else {
                            ApprovalCard(model: model, geometry: geometry, request: item.request, queued: model.pending.count)
                        }
                    }
                    .padding(.top, inset).padding(.horizontal, side).padding(.bottom, 16)
                }
            }
        }
    }

    private func measured<V: View>(_ state: IslandState, width: CGFloat, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .animation(nil, value: width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.report(height: $0, for: state) }
    }
}
