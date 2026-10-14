import Foundation
import SQLite3

/// One notification as stored by macOS, before names and icons are looked up.
struct RawNotification: Equatable {
    let recordID: Int64
    let bundleID: String
    let title: String?
    let subtitle: String?
    let body: String?
    let date: Date
    /// The conversation it belongs to, when the app gives one (Messages: "any;-;<handle>" for a one-to-one chat).
    var thread: String? = nil
    /// An id the app gives it (Messages: the message's guid), used to show one message only once.
    var guid: String? = nil
}

/// Reads the macOS notification database (read only). Needs Full Disk Access.
/// The text lives in a property-list blob; on current macOS it sits in a "req" dictionary.
final class NotificationReader {
    let path: String
    private var db: OpaquePointer?
    private(set) var lastRecordID: Int64 = 0
    /// Newest delivery time seen. macOS sometimes re-delivers a notification by updating its existing
    /// record (Messages does for a repeated alert): same rec_id, newer delivered_date.
    private(set) var lastDelivered: Double = 0

    init(path: String) { self.path = path }
    deinit { close() }

    /// Where the database lives on this Mac (it moves between macOS versions).
    static func databasePath(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        let g = home.appendingPathComponent("Library/Group Containers")
        let candidates = [
            g.appendingPathComponent("group.com.apple.usernoted/db2/db"),
            g.appendingPathComponent("group.com.apple.UserNotifications/db2/db"),
            g.appendingPathComponent("group.com.apple.usernoted/db/db"),
            g.appendingPathComponent("group.com.apple.UserNotifications/db/db"),
            home.appendingPathComponent("Library/Application Support/NotificationCenter/db2/db"),
        ].map(\.path)
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    var isReadable: Bool { FileManager.default.isReadableFile(atPath: path) }

    @discardableResult
    func open() -> Bool {
        if db != nil { return true }
        guard isReadable else { return false }
        return sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    /// Every app that macOS lets send notifications (its own list, not only the ones that already sent one).
    func registeredApps() -> [String] {
        guard open(), let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT identifier FROM app", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// Start from "now": notifications that already exist are not shown again.
    func skipExisting() {
        guard open(), let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(rec_id), MAX(delivered_date) FROM record", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return }
        lastRecordID = sqlite3_column_int64(stmt, 0)
        lastDelivered = sqlite3_column_double(stmt, 1)
    }

    /// Everything new or re-delivered since the last look, oldest first.
    func readNew() -> [RawNotification] {
        guard open(), let db else { return [] }
        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date
            FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? OR r.delivered_date > ? ORDER BY r.delivered_date ASC, r.rec_id ASC LIMIT 50
            """
        var stmt: OpaquePointer?
        // a connection that went bad (the database was rebuilt, access was lost) is dropped and opened fresh next time
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); close(); return []
        }
        sqlite3_bind_int64(stmt, 1, lastRecordID)
        sqlite3_bind_double(stmt, 2, lastDelivered)

        var out: [RawNotification] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            lastRecordID = max(lastRecordID, id)
            let bundle = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "unknown"
            if let blob = sqlite3_column_blob(stmt, 2) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
                let seconds = sqlite3_column_double(stmt, 3)
                lastDelivered = max(lastDelivered, seconds)
                let date = seconds > 0 ? Date(timeIntervalSinceReferenceDate: seconds) : Date()
                if let n = Self.parse(data: data, recordID: id, bundleID: bundle, date: date) { out.append(n) }
            }
            rc = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { close() }
        return out
    }

    static func parse(data: Data, recordID: Int64, bundleID: String, date: Date) -> RawNotification? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let content = (plist["req"] as? [String: Any]) ?? plist     // current macOS, then older layout
        var title = content["titl"] as? String
        var subtitle = content["subt"] as? String
        var body = content["body"] as? String
        if title == nil, let alert = (plist["aps"] as? [String: Any])?["alert"] {      // push notifications
            if let d = alert as? [String: Any] {
                title = d["title"] as? String; subtitle = d["subtitle"] as? String; body = d["body"] as? String
            } else if let s = alert as? String { body = s }
        }
        if title == nil && subtitle == nil && body == nil { return nil }
        return RawNotification(recordID: recordID, bundleID: bundleID, title: title, subtitle: subtitle, body: body, date: date,
                               thread: content["thre"] as? String, guid: content["iden"] as? String)
    }
}

/// Watches the database and its write-ahead log for changes, with a slow timer as a safety net.
final class NotificationWatcher {
    private let reader: NotificationReader
    private let queue = DispatchQueue(label: "notchplus.notifications")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private let onNew: ([RawNotification]) -> Void

    init(reader: NotificationReader, onNew: @escaping ([RawNotification]) -> Void) {
        self.reader = reader
        self.onNew = onNew
    }

    /// Returns false when the database cannot be read (no Full Disk Access).
    func start() -> Bool {
        guard reader.open() else { return false }
        queue.sync { reader.skipExisting() }
        for suffix in ["", "-wal"] {
            let fd = open(reader.path + suffix, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib], queue: queue)
            s.setEventHandler { [weak self] in self?.changed() }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        return true
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        timer?.cancel(); timer = nil
        debounce?.cancel()
    }

    private func changed() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.poll() }
        debounce = w
        queue.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    private func poll() {
        let found = reader.readNew()
        if !found.isEmpty { onNew(found) }
    }
}
