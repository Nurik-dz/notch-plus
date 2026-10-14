import SwiftUI

/// Claude asking you something (its own multiple choice question): the options as buttons, then Send.
/// "In terminal" gives the question back so Claude Code asks there as usual.
struct QuestionCard: View {
    @ObservedObject var model: NotchModel
    let geometry: NotchGeometry
    let request: ApprovalRequest
    let queued: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BesideNotch(geometry: geometry, cardWidth: NotchGeometry.approvalWidth) {
                ClaudeBadge(size: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Claude asks").font(Theme.label(11.5, .semibold))
                    if !request.folderName.isEmpty {
                        Text(request.folderName).font(Theme.label(9.5)).foregroundStyle(Theme.secondary).truncationMode(.middle)
                    }
                }
            } trailing: {
                if queued > 1 { Chip(text: "1 of \(queued)", color: Theme.blue) }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Elapsed.clock(ctx.date.timeIntervalSince(request.receivedAt)))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(model.isNudging(at: ctx.date) ? Theme.amber : Theme.tertiary)
                }
            }
            .rise(0)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(request.questions) { q in question(q) }
                }
            }
            .frame(maxHeight: 210)
            .fixedSize(horizontal: false, vertical: true)
            .rise(1)
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Button { model.answerQuestionsInTerminal() } label: {
                    HStack(spacing: 6) { Text("In terminal"); KeyBadge(text: HotKeys.labels.deny) }
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .help("Answer in the terminal instead")
                Button { model.answerQuestions() } label: {
                    HStack(spacing: 6) { Text("Send"); KeyBadge(text: HotKeys.labels.allow) }
                }
                .buttonStyle(PillButtonStyle(kind: .allow))
                .disabled(!model.questionsAnswered)
                .opacity(model.questionsAnswered ? 1 : 0.45)
                .accessibilityHint("Sends your choice to Claude")
            }
            .rise(2)
        }
    }

    private func question(_ q: ClaudeQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if !q.header.isEmpty { Chip(text: q.header, color: Theme.claude) }
                if q.multiSelect { Text("pick any").font(Theme.label(10)).foregroundStyle(Theme.tertiary) }
            }
            Text(q.question).font(Theme.title(15)).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(q.options) { o in option(o, in: q) }
            }
        }
    }

    private func option(_ o: ClaudeQuestion.Option, in q: ClaudeQuestion) -> some View {
        let picked = (model.questionPicks[q.question] ?? []).contains(o.label)
        return Button { withAnimation(Motion.hover) { model.pick(o, in: q) } } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: q.multiSelect ? (picked ? "checkmark.square.fill" : "square")
                                                : (picked ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(picked ? Theme.claude : Theme.tertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(o.title).font(Theme.label(12.5, .semibold)).foregroundStyle(.white)
                        if o.isRecommended { Chip(text: "Recommended", color: Theme.green) }
                    }
                    if !o.description.isEmpty {
                        Text(o.description).font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(picked ? Theme.claude.opacity(0.16) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(picked ? Theme.claude.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A permission request from Claude Code.
struct ApprovalCard: View {
    @ObservedObject var model: NotchModel
    let geometry: NotchGeometry
    let request: ApprovalRequest
    let queued: Int

    private var riskColor: Color {
        switch request.risk {
        case .low: Theme.green
        case .medium: Theme.amber
        case .high: Theme.red
        }
    }
    private var riskWord: String {
        switch request.risk {
        case .low: "Safe"
        case .medium: "Changes things"
        case .high: "Risky"
        }
    }
    private var riskSymbol: String {
        switch request.risk {
        case .low: "checkmark.shield.fill"
        case .medium: "pencil.circle.fill"
        case .high: "exclamationmark.triangle.fill"
        }
    }
    /// Shown when Apple Intelligence is off or still thinking.
    private var ruleSentence: String {
        switch request.risk {
        case .low: "Only reads. Nothing on your Mac changes."
        case .medium: "Makes a change on your Mac."
        case .high: "Could delete things or change something important."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header.rise(0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(request.headline).font(Theme.title(17)).lineLimit(2)
                    Spacer(minLength: 4)
                    if queued > 1 { Chip(text: "1 of \(queued)", color: Theme.blue) }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Elapsed.clock(ctx.date.timeIntervalSince(request.receivedAt)))
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(model.isNudging(at: ctx.date) ? Theme.amber : Theme.tertiary)
                    }
                }
                explanation
            }
            .rise(1)
            command.rise(2)
            buttons.rise(3)
        }
    }

    /// Beside the notch: who is asking and where on the left, how risky on the right.
    private var header: some View {
        BesideNotch(geometry: geometry, cardWidth: NotchGeometry.approvalWidth) {
            ClaudeBadge(size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude Code").font(Theme.label(11.5, .semibold))
                if let place = placeLine {
                    Text(place).font(Theme.label(9.5)).foregroundStyle(Theme.secondary).truncationMode(.middle)
                }
            }
        } trailing: {
            Chip(text: riskWord, symbol: riskSymbol, color: riskColor)
        }
    }

    /// The project folder and the branch, when known.
    private var placeLine: String? {
        let parts = [request.folderName.isEmpty ? nil : request.folderName, request.branch].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var explanation: some View {
        if let e = model.explanations[request.id] {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.violet)
                Text(e).font(Theme.text(12.5)).foregroundStyle(.white.opacity(0.86)).lineLimit(2)
            }
            .transition(.opacity.combined(with: .offset(y: 4)))
        } else if model.explaining.contains(request.id) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.violet)
                ShimmerBar(width: 210)
            }
        } else {
            Text(ruleSentence).font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
        }
    }

    private var command: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: request.symbol)
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                .padding(.top, 2).frame(width: 13)
            Group {
                if request.tool == "Bash" {
                    Text("$ ").foregroundStyle(Theme.claude) + Text(request.detail).foregroundStyle(.white.opacity(0.92))
                } else {
                    Text(request.detail.isEmpty ? request.tool : request.detail).foregroundStyle(.white.opacity(0.92))
                }
            }
            .font(Theme.mono(11.5))
            .lineLimit(3).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var buttons: some View {
        HStack(spacing: 7) {
            Spacer(minLength: 0)
            Button { model.answer(allow: false) } label: {
                HStack(spacing: 6) { Text("Deny"); KeyBadge(text: HotKeys.labels.deny) }
            }
            .buttonStyle(PillButtonStyle(kind: .deny))
            .accessibilityLabel("Deny").accessibilityHint("Stops Claude from doing this")
            if request.canAllowAlways {
                Button { model.answer(allow: true, always: true) } label: {
                    HStack(spacing: 6) { Text("Always"); KeyBadge(text: HotKeys.labels.always) }
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .accessibilityLabel("Always allow").accessibilityHint("Allows this and remembers the choice")
            }
            Button { model.answer(allow: true) } label: {
                HStack(spacing: 6) {
                    Text(request.risk == .high ? "Allow anyway" : "Allow")
                    KeyBadge(text: HotKeys.labels.allow)
                }
            }
            .buttonStyle(PillButtonStyle(kind: request.risk == .high ? .danger : .allow))
            .accessibilityLabel(request.risk == .high ? "Allow anyway" : "Allow").accessibilityHint(request.risk == .high ? "This is marked risky" : "Lets Claude do this once")
        }
    }
}
