import Foundation

/// Connects Notch+ to Claude Code by adding hooks to ~/.claude/settings.json:
/// one that waits for your answer on permission requests, and quick ones that report what Claude is doing.
/// Always shows what it will add, saves a backup first, and removes only its own entries.
struct HookInstaller {
    let paths: AppPaths

    enum Status: Equatable {
        case notConnected
        case connected
        case outdated          // connected by an older Notch+; connect again to add live status
        case problem(String)
    }

    enum InstallError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case .unreadable(let m) = self { return m }
            return nil
        }
    }

    /// Event name, how the script treats it, and Claude Code's timeout in seconds.
    static let events: [(name: String, kind: String, timeout: Int)] = [
        ("PermissionRequest", "permission", 590),
        ("UserPromptSubmit", "event", 5),
        ("PreToolUse", "event", 5),
        ("PostToolUse", "event", 5),
        ("Notification", "event", 5),
        ("Stop", "event", 5),
        ("SessionStart", "event", 5),
        ("SessionEnd", "event", 5),
    ]

    /// The script Claude Code runs. It prints nothing when Notch+ is not running,
    /// so Claude Code then asks in the terminal as usual.
    var scriptText: String {
        """
        #!/bin/bash
        # Notch+ hook for Claude Code. Sends the event to the Notch+ app and prints its answer.
        # "permission" waits for your answer in the notch; "event" only reports status and returns at once.
        # If Notch+ is not running this prints nothing, so Claude Code behaves exactly as without it.
        TOKEN_FILE="\(paths.token.path)"
        [ -r "$TOKEN_FILE" ] || exit 0
        if [ "$1" = "permission" ]; then MAX=590; ENDPOINT=permission; else MAX=2; ENDPOINT=event; fi
        /usr/bin/curl -s --max-time $MAX --connect-timeout 1 -X POST \\
          -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \\
          -H "Content-Type: application/json" \\
          --data-binary @- "http://127.0.0.1:\(NotchConfig.port)/$ENDPOINT"
        exit 0

        """
    }

    /// The script path, quoted for the shell Claude Code runs it through (the path contains a space).
    var quotedScript: String {
        "'" + paths.hookScript.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func command(kind: String) -> String { quotedScript + " " + kind }

    private func entry(kind: String, timeout: Int) -> [String: Any] {
        ["hooks": [["type": "command", "command": command(kind: kind), "timeout": timeout]]]
    }

    /// The exact text that will be added, for the confirmation screen.
    func previewText() -> String {
        var hooks: [String: Any] = [:]
        for e in Self.events { hooks[e.name] = [entry(kind: e.kind, timeout: e.timeout)] }
        return Self.pretty(["hooks": hooks])
    }

    func status() -> Status {
        do {
            let settings = try readSettings()
            let have = Self.events.filter { e in groups(settings, e.name).contains(where: isOurs) }.count
            if have == Self.events.count { return .connected }
            return have == 0 ? .notConnected : .outdated
        } catch {
            return .problem(error.localizedDescription)
        }
    }

    /// Returns true when a backup of an existing settings file was saved.
    @discardableResult
    func connect() throws -> Bool {
        var settings = try readSettings()
        _ = TokenStore.load(paths)
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try scriptText.write(to: paths.hookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.hookScript.path)

        for e in Self.events {
            var g = groups(settings, e.name).filter { !isOurs($0) }
            g.append(entry(kind: e.kind, timeout: e.timeout))
            settings = setGroups(settings, e.name, g)
        }
        return try write(settings)
    }

    @discardableResult
    func disconnect() throws -> Bool {
        var settings = try readSettings()
        for e in Self.events {
            settings = setGroups(settings, e.name, groups(settings, e.name).filter { !isOurs($0) })
        }
        return try write(settings)
    }

    // MARK: - JSON helpers

    private func readSettings() throws -> [String: Any] {
        let url = paths.claudeSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.unreadable("Claude Code's settings file is not valid JSON, so Notch+ left it alone.")
        }
        return obj
    }

    private func groups(_ s: [String: Any], _ event: String) -> [[String: Any]] {
        ((s["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    private func setGroups(_ s: [String: Any], _ event: String, _ g: [[String: Any]]) -> [String: Any] {
        var settings = s
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        if g.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = g }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    /// True for entries written by any Notch+ build (the plain path is what the first build wrote).
    private func isOurs(_ group: [String: Any]) -> Bool {
        ((group["hooks"] as? [[String: Any]]) ?? []).contains {
            guard let c = $0["command"] as? String else { return false }
            return c == paths.hookScript.path || c.hasPrefix(quotedScript)
        }
    }

    private func write(_ settings: [String: Any]) throws -> Bool {
        let url = paths.claudeSettings
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backedUp = false
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: paths.claudeSettingsBackup)
            try fm.copyItem(at: url, to: paths.claudeSettingsBackup)
            backedUp = true
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return backedUp
    }

    static func pretty(_ obj: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
