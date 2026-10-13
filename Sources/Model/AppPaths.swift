import Foundation
import Security

enum NotchConfig {
    static let port: UInt16 = 47653
}

/// All file locations in one place so tests can point at a scratch home.
struct AppPaths {
    let home: URL
    init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) { self.home = home }

    var support: URL { home.appendingPathComponent("Library/Application Support/NotchPlus") }
    var token: URL { support.appendingPathComponent("token") }
    var hookScript: URL { support.appendingPathComponent("hook.sh") }
    var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    var shelfFile: URL { support.appendingPathComponent("shelf.json") }
    var basketFile: URL { support.appendingPathComponent("basket.json") }
    var claudeSettingsBackup: URL { home.appendingPathComponent(".claude/settings.json.notchplus-backup") }
}

/// The secret that proves a request really comes from the Notch+ hook script.
enum TokenStore {
    static func load(_ paths: AppPaths) -> String {
        if let existing = try? String(contentsOf: paths.token, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try? token.write(to: paths.token, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.token.path)
        return token
    }
}
