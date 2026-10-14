import SwiftUI
import AppKit

/// What a file action produced (or why it failed).
struct ResultCard: View {
    @ObservedObject var model: NotchModel
    let geometry: NotchGeometry
    let outcome: NotchModel.Outcome2

    var body: some View {
        switch outcome {
        case .done(let result, let source): done(result, source)
        case .failed(let message, let source): failed(message, source)
        }
    }

    /// Beside the notch: a coloured mark and a word on the left, the close button on the right.
    private func top(symbol: String, word: String, color: Color) -> some View {
        BesideNotch(geometry: geometry, cardWidth: NotchGeometry.resultWidth) {
            ZStack {
                Circle().fill(color.opacity(0.2)).frame(width: 18, height: 18)
                Image(systemName: symbol).font(.system(size: 9, weight: .heavy)).foregroundStyle(color)
            }
            .shadow(color: color.opacity(0.6), radius: 6)
            Text(word).font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.6).foregroundStyle(color)
        } trailing: {
            Button { model.dismissOutcome() } label: { Image(systemName: "xmark") }
                .buttonStyle(RoundIconButtonStyle()).accessibilityLabel("Dismiss")
        }
    }

    private func done(_ result: ActionResult, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            top(symbol: "sparkles", word: "DONE", color: Theme.green).rise(0)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).font(Theme.title(15)).lineLimit(1)
                    Text(source + (result.files.count > 1 ? "  ·  \(result.files.count) files saved" : "  ·  saved next to it"))
                        .font(Theme.label(11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                }
                .rise(1)
                Spacer(minLength: 4)
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
            top(symbol: "exclamationmark", word: "FAILED", color: Theme.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Could not finish").font(Theme.title(15))
                Text(source).font(Theme.label(11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
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
