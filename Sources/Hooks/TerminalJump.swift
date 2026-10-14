import AppKit

/// Which terminal a Claude session runs in, as the hook script reports it (from the environment Claude
/// Code passes to hooks, checked on 2026-10-13: TERM_PROGRAM, TERM_SESSION_ID, ITERM_SESSION_ID, and the
/// tty of the claude process).
struct TerminalRef: Equatable {
    static let key = "_notch_terminal"

    var program: String       // "Apple_Terminal", "iTerm.app", "vscode", "ghostty", ...
    var tab: String           // Terminal.app's TERM_SESSION_ID
    var iterm: String         // iTerm2's ITERM_SESSION_ID, "w0t1p0:<uuid>"
    var tty: String           // "ttys000"

    init?(_ json: [String: Any]) {
        guard let d = json[Self.key] as? [String: String] else { return nil }
        program = d["program"] ?? ""; tab = d["tab"] ?? ""; iterm = d["iterm"] ?? ""; tty = d["tty"] ?? ""
        if program.isEmpty && tty.isEmpty { return nil }
    }

    init(program: String, tab: String = "", iterm: String = "", tty: String = "") {
        self.program = program; self.tab = tab; self.iterm = iterm; self.tty = tty
    }

    /// The app to bring forward when its tab cannot be picked exactly.
    var bundleID: String? {
        switch program {
        case "Apple_Terminal": "com.apple.Terminal"
        case "iTerm.app": "com.googlecode.iterm2"
        case "vscode": "com.microsoft.VSCode"
        case "ghostty": "com.mitchellh.ghostty"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        case "WezTerm": "com.github.wez.wezterm"
        case "zed": "dev.zed.Zed"
        default: nil
        }
    }

    /// A readable name, for the help text.
    var appName: String {
        switch program {
        case "Apple_Terminal": "Terminal"
        case "iTerm.app": "iTerm2"
        case "vscode": "VS Code"
        case "": "the terminal"
        default: program.replacingOccurrences(of: ".app", with: "")
        }
    }
}

/// Brings the exact terminal tab of a Claude session to the front: Terminal.app and iTerm2 by script
/// (asks once for permission to control them), any other app by activating it.
enum TerminalJump {
    /// The AppleScript that selects the tab, or nil when the app has no way to pick a tab.
    static func script(for t: TerminalRef) -> String? {
        switch t.program {
        case "Apple_Terminal" where !t.tty.isEmpty:
            let tty = "/dev/" + t.tty.replacingOccurrences(of: "\"", with: "")
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                    activate
                end tell
                """
        case "iTerm.app" where t.iterm.contains(":"):
            let uuid = String(t.iterm.split(separator: ":", maxSplits: 1)[1]).replacingOccurrences(of: "\"", with: "")
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if unique id of s is "\(uuid)" then
                                    tell w to select
                                    tell t to select
                                    tell s to select
                                    activate
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                    activate
                end tell
                """
        default:
            return nil
        }
    }

    @MainActor
    static func focus(_ t: TerminalRef) {
        if let source = script(for: t), let s = NSAppleScript(source: source) {
            var error: NSDictionary?
            s.executeAndReturnError(&error)
            if error == nil { return }
        }
        // no script, or not allowed: at least bring the app forward
        if let id = t.bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        }
    }
}
