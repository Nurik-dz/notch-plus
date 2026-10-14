import SwiftUI
import AppKit

// MARK: - Dragging many files at once

/// A transparent layer that starts a real drag of several files together (all selected files at once),
/// and reports whether they were dropped somewhere or the drag was cancelled.
struct DragFilesHandle: NSViewRepresentable {
    let urls: () -> [URL]
    let ended: (Bool) -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let v = DragSourceView()
        v.urls = urls
        v.ended = ended
        return v
    }

    func updateNSView(_ v: DragSourceView, context: Context) {
        v.urls = urls
        v.ended = ended
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var ended: (Bool) -> Void = { _ in }
    private var downAt: NSPoint?
    private var began = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }       // works even though the island is not the active window
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow; began = false }
    override func mouseUp(with event: NSEvent) { downAt = nil; began = false }

    override func mouseDragged(with event: NSEvent) {
        guard !began, let start = downAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 else { return }
        let files = urls()
        guard !files.isEmpty else { return }
        began = true
        let local = convert(event.locationInWindow, from: nil)
        let items = files.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 40, height: 40)
            let offset = CGFloat(min(i, 4)) * 4
            item.setDraggingFrame(NSRect(x: local.x - 20 + offset, y: local.y - 20 - offset, width: 40, height: 40), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dropped = operation != []
        DispatchQueue.main.async { [weak self] in self?.ended(dropped) }
    }
}

// MARK: - The grid of files

/// The files of one list (the shelf, or the basket's own), as a grid you can select from:
/// click, Command-click to add or remove one, Shift-click for a range.
struct FileGrid: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: ShelfStore
    let columns: Int
    let maxHeight: CGFloat
    var showsDropPlaceholder = false
    /// Files that are leaving for the shelf: they rise toward the notch and fade.
    var flying: Set<UUID> = []

    private static let tile: CGFloat = 66
    private static let rowHeight: CGFloat = 82

    var body: some View {
        let ids = store.items.map(\.id)
        let count = store.items.count + (showsDropPlaceholder ? 1 : 0)
        let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
        let height = min(maxHeight, CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * 6 + 4)
        ScrollView(.vertical, showsIndicators: rows * Int(Self.rowHeight) > Int(maxHeight)) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tile + 4), spacing: 6), count: columns), alignment: .leading, spacing: 6) {
                ForEach(store.items) { item in
                    let leaving = flying.contains(item.id)
                    ShelfTile(model: model, shelf: store, item: item, selected: model.selection.contains(item.id)) {
                        withAnimation(Motion.hover) { model.clickFile(item.id, in: store) }
                    }
                    .offset(y: leaving ? -90 : 0)
                    .scaleEffect(leaving ? 0.35 : 1)
                    .opacity(leaving ? 0 : 1)
                    .animation(.easeIn(duration: 0.4), value: leaving)
                }
                if showsDropPlaceholder {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.blue, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .frame(width: Self.tile - 10, height: Self.tile - 10)
                        .overlay(Image(systemName: "plus").foregroundStyle(Theme.blue))
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: height)
        .onChange(of: ids) { old, new in
            let added = Set(new).subtracting(old)
            if !added.isEmpty { model.selection.select(added) }      // new files (or a result) are selected at once, ready to drag on together
            else { model.selection.prune(keeping: new) }
        }
        .onAppear {
            model.selection.prune(keeping: ids)
            if model.selection.isEmpty, let first = ids.first { model.selection.select([first]) }
        }
    }
}

// MARK: - What can be done with several files

struct FileBulkBar: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: ShelfStore

    private var items: [ShelfItem] { store.items.filter { model.selection.contains($0.id) } }
    private var urls: [URL] { items.compactMap { store.url(for: $0) } }

    var body: some View {
        let n = items.count
        HStack(spacing: 6) {
            if let job = model.jobs.last(where: { j in items.contains { $0.id == j.itemID } }) {
                Image(systemName: "sparkles").foregroundStyle(Theme.violet).symbolEffect(.pulse)
                Text("\(job.verb)… \(job.fraction.map { "\(Int($0 * 100))%" } ?? job.status)")
                    .font(Theme.label(12, .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Text("\(n) selected").font(Theme.label(12, .semibold)).foregroundStyle(.white.opacity(0.9)).fixedSize()
                dragChip(n)
                Button { model.startZip(items) } label: {
                    Label("Zip", systemImage: "doc.zipper").labelStyle(.titleAndIcon)
                        .font(Theme.label(11.5, .semibold))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(Theme.violet.opacity(0.22)))
                        .overlay(Capsule().strokeBorder(Theme.violet.opacity(0.5), lineWidth: 0.8))
                }
                .buttonStyle(.plain).hoverLift(1.04)
                .help("Put the selected files in one zip, next to the first one")
                Menu {
                    Button("Copy paths") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                    Divider()
                    Button("Select all") { model.selection.selectAll(store.items.map(\.id)) }
                    Button("Select none") { model.selection.clear() }
                    Divider()
                    Button("Remove selected from the list") {
                        for i in items { store.remove(i.id) }
                        model.selection.clear()
                    }
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
            }
        }
        .frame(height: 30)
    }

    /// The handle: drag this and every selected file goes with it.
    private func dragChip(_ n: Int) -> some View {
        Label("Drag \(n)", systemImage: "arrow.up.forward.square.fill").labelStyle(.titleAndIcon)
            .font(Theme.label(11.5, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 28)
            .background(Capsule().fill(LinearGradient(colors: [Theme.blue.opacity(0.8), Theme.violet.opacity(0.8)], startPoint: .leading, endPoint: .trailing)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
            .overlay {
                DragFilesHandle(urls: { urls }) { dropped in
                    model.dragOutEnded(items.map(\.id), droppedSomewhere: dropped)
                }
            }
            .fixedSize()
            .help("Drag all \(n) selected files into any app")
            .accessibilityLabel("Drag \(n) selected files")
    }
}

/// Translate to: a short list of the languages you probably want, the rest one step further, not twenty at once.
struct LanguageMenu: View {
    let title: String
    let actions: [FileAction]
    let run: (FileAction) -> Void

    private func language(_ a: FileAction) -> String { String(a.id.split(separator: ":").last ?? "") }

    var body: some View {
        let first = Translator.favourites(from: actions.map(language))
        let top = first.compactMap { id in actions.first { language($0) == id } }
        let rest = actions.filter { a in !first.contains(language(a)) }
        Menu(title) {
            ForEach(top) { a in Button(a.title) { run(a) } }
            if !rest.isEmpty {
                Divider()
                Menu("More languages") { ForEach(rest) { a in Button(a.title) { run(a) } } }
            }
        }
    }
}
