import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    var path: String
    var bookmark: Data?
    var name: String
    var added: Date
}

/// Files parked on the notch. The shelf keeps links to your files; it never copies or moves them.
@MainActor
final class ShelfStore: ObservableObject {
    static let limit = 30

    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    private let file: URL

    init(file: URL) {
        self.file = file
        load()
    }

    // MARK: - Items

    /// Adds files; returns how many were new. Folders and files both work; duplicates are ignored.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path), !items.contains(where: { $0.path == path }) else { continue }
            let item = ShelfItem(id: UUID(), path: path, bookmark: try? url.bookmarkData(),
                                 name: url.lastPathComponent, added: Date())
            items.insert(item, at: 0)
            added += 1
        }
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        if added > 0 { save() }
        return added
    }

    /// Forgets links older than the given age. Only the links; the files are never touched.
    func prune(olderThan age: TimeInterval, now: Date = Date()) {
        let kept = items.filter { now.timeIntervalSince($0.added) < age }
        guard kept.count != items.count else { return }
        let gone = Set(items.map(\.id)).subtracting(kept.map(\.id))
        items = kept
        for id in gone { thumbnails.removeValue(forKey: id) }
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        thumbnails.removeValue(forKey: id)
        save()
    }

    func clear() {
        items = []
        thumbnails = [:]
        save()
    }

    /// Where the file is now (follows it if it was moved or renamed), or nil if it is gone.
    func url(for item: ShelfItem) -> URL? {
        if let data = item.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return FileManager.default.fileExists(atPath: item.path) ? URL(fileURLWithPath: item.path) : nil
    }

    func isMissing(_ item: ShelfItem) -> Bool { url(for: item) == nil }

    // MARK: - Thumbnails

    func loadThumbnail(for item: ShelfItem, size: CGFloat = 56) {
        guard thumbnails[item.id] == nil, let url = url(for: item) else { return }
        // The file's icon straight away; a real preview a moment later, but only for pictures, PDFs and video
        // (text files would just show a tiny white page).
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: url.path)
        let type = UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true || type?.conforms(to: .movie) == true else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let cg = rep?.cgImage else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
            Task { @MainActor in self?.thumbnails[item.id] = image }
        }
    }

    // MARK: - Saving

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = saved
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: file, options: .atomic) }
    }
}

enum DragDetector {
    /// Is the drag in progress carrying files? (Read from the system's drag pasteboard.)
    static func carriesFiles(_ pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}
