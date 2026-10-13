import SwiftUI
import AppKit

/// What a file action produced (or why it failed).
struct ResultCard: View {
    @ObservedObject var model: NotchModel
    let outcome: NotchModel.Outcome2

    var body: some View {
        switch outcome {
        case .done(let result, let source): done(result, source)
        case .failed(let message, let source): failed(message, source)
        }
    }

    private func done(_ result: ActionResult, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.green.opacity(0.18)).frame(width: 36, height: 36)
                    Image(systemName: "sparkles").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.green)
                }
                .shadow(color: Theme.green.opacity(0.5), radius: 8)
                .rise(0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).font(Theme.title(14)).lineLimit(1)
                    Text(source + (result.files.count > 1 ? "  ·  \(result.files.count) files saved" : "  ·  saved next to it"))
                        .font(Theme.label(11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                }
                .rise(1)
                Spacer(minLength: 4)
                Button { model.dismissOutcome() } label: { Image(systemName: "xmark") }
                    .buttonStyle(RoundIconButtonStyle()).accessibilityLabel("Dismiss")
            }
            if let text = result.text, !text.isEmpty {
                Text(text)
                    .font(Theme.text(12)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                    .rise(2)
            }
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                if let text = result.text, !text.isEmpty {
                    Button { copy(text) } label: { Label("Copy text", systemImage: "doc.on.doc") }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                }
                if let first = result.files.first {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([first]) } label: { Label("Show", systemImage: "folder") }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                    Button { NSWorkspace.shared.open(first); model.dismissOutcome() } label: { Text("Open") }
                        .buttonStyle(PillButtonStyle(kind: .allow))
                }
            }
            .rise(3)
            TimerBar(color: Theme.green, seconds: 14).id(model.outcomeStamp)
        }
    }

    private func failed(_ message: String, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.red.opacity(0.18)).frame(width: 36, height: 36)
                    Image(systemName: "exclamationmark").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.red)
                }
                .shadow(color: Theme.red.opacity(0.5), radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Could not finish").font(Theme.title(14))
                    Text(source).font(Theme.label(11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button { model.dismissOutcome() } label: { Image(systemName: "xmark") }
                    .buttonStyle(RoundIconButtonStyle()).accessibilityLabel("Dismiss")
            }
            Text(message).font(Theme.text(12)).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimerBar(color: Theme.red, seconds: 14).id(model.outcomeStamp)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
