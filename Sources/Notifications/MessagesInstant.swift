import Foundation
import SQLite3

/// macOS writes a Messages notification into its notification database only 8 to 13 seconds after the message
/// arrives (measured on macOS 27), but Messages' own database has the message about one second after it is sent.
/// This reads that one, so a message card appears at once. The notification record that comes later carries the
/// same id (its "iden" is the message's guid) and is recognised and skipped. Read only; needs Full Disk Access.

/// Messages keeps the words of many messages only inside a typed-stream blob (attributedBody), not in `text`.
enum MessageText {
    static func extract(from raw: Data) -> String? {
        let blob = Data(raw)                                     // indices from zero
        guard let r = blob.range(of: Data("NSString".utf8)) else { return nil }
        var i = r.upperBound + 5                                 // the class description bytes that follow the name
        guard i < blob.count else { return nil }
        var length = Int(blob[i]); i += 1
        if length == 0x81 {                                      // long form: two bytes, little endian
            guard i + 2 <= blob.count else { return nil }
            length = Int(blob[i]) | (Int(blob[i + 1]) << 8); i += 2
        }
        guard length > 0, i + length <= blob.count else { return nil }
        let text = String(data: blob[i..<(i + length)], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}

/// Names from the Contacts database, so a message card says "Mum", not a phone number (what macOS does too).
final class ContactNames: @unchecked Sendable {
    private var byPhone: [String: String] = [:]
    private var byEmail: [String: String] = [:]
    private var loaded: Date = .distantPast
    private let paths: () -> [String]

    init(paths: @escaping () -> [String] = ContactNames.systemPaths) { self.paths = paths }

    static func systemPaths() -> [String] {
        let base = NSHomeDirectory() + "/Library/Application Support/AddressBook"
        var out = [base + "/AddressBook-v22.abcddb"]
        let sources = (try? FileManager.default.contentsOfDirectory(atPath: base + "/Sources")) ?? []
        out += sources.map { base + "/Sources/" + $0 + "/AddressBook-v22.abcddb" }
        return out.filter { FileManager.default.isReadableFile(atPath: $0) }
    }

    static func digits(_ s: String) -> String { String(s.filter(\.isNumber).suffix(10)) }      // the last ten digits: the country code does not matter

    func name(for handle: String, now: Date = Date()) -> String? {
        if now.timeIntervalSince(loaded) > 300 { reload(now: now) }
        if handle.contains("@") { return byEmail[handle.lowercased()] }
        let d = Self.digits(handle)
        return d.count >= 7 ? byPhone[d] : nil
    }

    private func reload(now: Date) {
        loaded = now
        var phones: [String: String] = [:], emails: [String: String] = [:]
        for path in paths() {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); continue }
            defer { sqlite3_close(db) }
            var names: [Int64: String] = [:]
            query(db, "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZNICKNAME, ZORGANIZATION FROM ZABCDRECORD") { s in
                let first = Self.text(s, 1), last = Self.text(s, 2)
                let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                let name = !full.isEmpty ? full : (!Self.text(s, 3).isEmpty ? Self.text(s, 3) : Self.text(s, 4))
                if !name.isEmpty { names[sqlite3_column_int64(s, 0)] = name }
            }
            query(db, "SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER") { s in
                if let n = names[sqlite3_column_int64(s, 0)] { let d = Self.digits(Self.text(s, 1)); if d.count >= 7 { phones[d] = n } }
            }
            query(db, "SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS") { s in
                if let n = names[sqlite3_column_int64(s, 0)] { emails[Self.text(s, 1).lowercased()] = n }
            }
        }
        byPhone = phones; byEmail = emails
    }

    private func query(_ db: OpaquePointer?, _ sql: String, row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { sqlite3_finalize(stmt); return }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { row(s) }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }
}

final class MessagesWatcher {
    private let path: String
    private let contacts: ContactNames
    private var db: OpaquePointer?
    private(set) var lastRowID: Int64 = 0
    private var firstSeen: [Int64: Date] = [:]
    private let queue = DispatchQueue(label: "notchplus.messages")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    var onNew: (([RawNotification]) -> Void)?

    init(path: String = NSHomeDirectory() + "/Library/Messages/chat.db", contacts: ContactNames = ContactNames()) {
        self.path = path
        self.contacts = contacts
    }
    deinit { stop(); sqlite3_close(db) }

    /// Opens the database and starts after the newest message (older ones are never shown).
    func open() -> Bool {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); db = nil; return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ROWID), 0) FROM message", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { lastRowID = sqlite3_column_int64(stmt, 0) }
        return true
    }

    func start() {
        for suffix in ["", "-wal"] {
            let fd = Foundation.open(path + suffix, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib], queue: queue)
            s.setEventHandler { [weak self] in self?.changed() }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
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
        queue.asyncAfter(deadline: .now() + 0.04, execute: w)
    }

    private func poll() {
        let found = readNew()
        if !found.isEmpty { onNew?(found) }
    }

    /// New incoming messages worth a card: unread, from a conversation that is not filtered or hidden, real text
    /// (not reactions, not system lines). A message whose conversation or words are not stored yet is waited for
    /// (up to a few seconds), because Messages writes the pieces one after another.
    func readNew(now: Date = Date()) -> [RawNotification] {
        guard let db else { return [] }
        let sql = """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, h.id, c.style, c.display_name, c.chat_identifier,
                   COALESCE(c.is_filtered, 0), COALESCE(c.is_blackholed, 0), COALESCE(m.date_read, 0),
                   COALESCE(m.associated_message_type, 0), COALESCE(m.item_type, 0), COALESCE(m.is_system_message, 0)
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = j.chat_id
            WHERE m.ROWID > ? AND m.is_from_me = 0
            ORDER BY m.ROWID LIMIT 50
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { sqlite3_finalize(stmt); return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, lastRowID)
        func str(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }

        var out: [RawNotification] = []
        var seen = Set<Int64>()
        while sqlite3_step(s) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(s, 0)
            if !seen.insert(rowID).inserted { continue }                       // a message in several chats: once
            var words = str(2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if words.isEmpty, let p = sqlite3_column_blob(s, 3) {
                words = MessageText.extract(from: Data(bytes: p, count: Int(sqlite3_column_bytes(s, 3)))) ?? ""
            }
            let chatID = str(7)
            let ready = chatID != nil && !words.isEmpty
            let reaction = sqlite3_column_int(s, 11) != 0, other = sqlite3_column_int(s, 12) != 0 || sqlite3_column_int(s, 13) != 0
            let hidden = sqlite3_column_int(s, 8) != 0 || sqlite3_column_int(s, 9) != 0 || sqlite3_column_int64(s, 10) != 0
            if !ready && !reaction && !other && !hidden {
                let first = firstSeen[rowID] ?? now
                firstSeen[rowID] = first
                if now.timeIntervalSince(first) < 6 { break }                  // wait for the rest of it, and do not pass it
            }
            lastRowID = rowID
            firstSeen[rowID] = nil
            guard ready, !reaction, !other, !hidden else { continue }
            let handle = str(4) ?? chatID ?? ""
            let isGroup = sqlite3_column_int(s, 5) == 43
            let who = contacts.name(for: handle) ?? handle
            out.append(RawNotification(recordID: -rowID, bundleID: "com.apple.MobileSMS", title: who,
                                       subtitle: isGroup ? str(6) : nil, body: words, date: now,
                                       thread: isGroup ? nil : "any;-;" + handle, guid: str(1)))
        }
        return out
    }
}
