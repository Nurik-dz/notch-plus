import Foundation
import SQLite3

/// Replying to a Messages notification from the notch. Only one-to-one chats: the notification's thread id
/// is "any;-;<handle>" (checked on macOS 27), and Messages' scripting can send to that handle. Group chats
/// ("any;+;...") are not offered. Nothing is ever sent without the user pressing Send.
enum MessagesReply {
    static let bundleID = "com.apple.mobilesms"

    /// The phone number or email to answer, when this notification can be answered from the notch.
    static func handle(for raw: RawNotification) -> String? {
        guard raw.bundleID.lowercased() == bundleID, let thread = raw.thread else { return nil }
        guard let range = thread.range(of: ";-;") else { return nil }       // ";+;" is a group chat
        let handle = String(thread[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return handle.isEmpty ? nil : handle
    }

    enum SendError: LocalizedError {
        case notAllowed
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notAllowed: "Notch+ is not allowed to use Messages yet. Allow it in System Settings > Privacy & Security > Automation."
            case .failed(let m): "Messages could not send it: \(m)"
            }
        }
    }

    /// The AppleScript that sends `text` to `handle`: iMessage first, then SMS for phone numbers without iMessage.
    static func script(text: String, to handle: String) -> String {
        let t = escape(text), h = escape(handle)
        return """
            tell application "Messages"
                try
                    set s to 1st account whose service type = iMessage
                    send "\(t)" to participant "\(h)" of s
                on error
                    set s to 1st account whose service type = SMS
                    send "\(t)" to participant "\(h)" of s
                end try
            end tell
            """
    }

    /// Text inside an AppleScript string: backslashes and quotes escaped, line breaks kept.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A few of the user's own earlier messages in this chat (newest first), so suggested replies can sound
    /// like them. Read only from ~/Library/Messages/chat.db (Full Disk Access); nothing is kept.
    static func recentSent(to handle: String, limit: Int = 8,
                           database: String = NSHomeDirectory() + "/Library/Messages/chat.db") -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT m.text FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
            WHERE c.chat_identifier = ? AND m.is_from_me = 1 AND m.text IS NOT NULL AND length(m.text) > 0
            ORDER BY m.date DESC LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, handle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(String(cString: c).prefix(200))) }
        }
        return out
    }

    /// Sends the message through Messages (asks once for permission to control Messages).
    @MainActor
    static func send(_ text: String, to handle: String) async throws {
        let source = script(text: text, to: handle)
        var error: NSDictionary?
        guard let s = NSAppleScript(source: source) else { throw SendError.failed("the script could not be prepared") }
        s.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 || code == -1744 { throw SendError.notAllowed }
            throw SendError.failed(error[NSAppleScript.errorMessage] as? String ?? "error \(code)")
        }
    }
}
