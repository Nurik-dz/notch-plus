import SwiftUI

/// A permission request from Claude Code.
struct ApprovalCard: View {
    @ObservedObject var model: NotchModel
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
                Text(request.headline).font(Theme.title(17))
                explanation
            }
            .rise(1)
            command.rise(2)
            buttons.rise(3)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ClaudeBadge(size: 24)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Claude Code").font(Theme.label(12, .semibold))
                    if queued > 1 { Chip(text: "1 of \(queued)", color: Theme.blue) }
                }
                HStack(spacing: 4) {
                    if !request.folderName.isEmpty {
                        Image(systemName: "folder.fill").font(.system(size: 8.5))
                        Text(request.folderName).lineLimit(1)
                    }
                    if let b = request.branch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5))
                        Text(b).lineLimit(1)
                    }
                }
                .font(Theme.label(10.5)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 6)
            Chip(text: riskWord, symbol: riskSymbol, color: riskColor)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Elapsed.clock(ctx.date.timeIntervalSince(request.receivedAt)))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.tertiary)
            }
        }
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
