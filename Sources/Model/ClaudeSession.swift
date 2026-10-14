import Foundation

/// What Claude Code is doing in one terminal session, built from its hook events.
struct ClaudeSession: Identifiable, Equatable {
    enum Status { case idle, working, waiting, done }

    let id: String
    var cwd: String
    var branch: String?
    var status: Status = .idle
    var tool: String?
    var turnStart: Date?
    var lastEvent = Date()
    /// When this session was first seen.
    var started = Date()
    /// The start of Claude's last answer (from the Stop event), for the sessions list.
    var lastReply: String?
    /// The terminal it runs in, to jump back to it.
    var terminal: TerminalRef?

    var project: String { cwd.isEmpty ? "Claude" : (cwd as NSString).lastPathComponent }

    /// A short, friendly name for the tool Claude is using, for the slim strip beside the notch.
    static func shortTool(_ tool: String?) -> String {
        guard let tool, !tool.isEmpty else { return "Thinking" }
        switch tool {
        case "Bash": return "Bash"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edit"
        case "Write": return "Write"
        case "Read": return "Read"
        case "Grep", "WebSearch": return "Search"
        case "Glob", "LS": return "Find"
        case "WebFetch": return "Web"
        case "Task", "Agent": return "Agent"
        case "TodoWrite": return "Plan"
        default: return tool.hasPrefix("mcp__") ? "Tool" : String(tool.prefix(8))
        }
    }

    /// Working sessions that have been silent for this long are treated as stopped
    /// (pressing Esc in the terminal sends no event).
    static let staleAfter: TimeInterval = 120
    var isLive: Bool { status == .working && Date().timeIntervalSince(lastEvent) < Self.staleAfter }
}

/// A task Claude has just finished, for the "Claude finished" card.
struct ClaudeFinish: Identifiable, Equatable {
    let id = UUID()
    let project: String
    let branch: String?
    let duration: TimeInterval?
    let message: String?
    /// The terminal Claude runs in, for "Go to terminal" on the card.
    var terminal: TerminalRef? = nil
    let date = Date()
}

enum Elapsed {
    /// 42 -> "0:42", 754 -> "12:34", 4000 -> "1:06:40"
    static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// How long ago, short: "now", "40s", "10m", "3h", "2d"
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let t = Int(now.timeIntervalSince(date))
        if t < 10 { return "now" }
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m" }
        if t < 86400 { return "\(t / 3600)h" }
        return "\(t / 86400)d"
    }
    /// 42 -> "42 s", 134 -> "2 min 14 s"
    static func words(_ s: TimeInterval) -> String {
        let t = Int(s)
        if t < 60 { return "\(t) s" }
        let m = t / 60, sec = t % 60
        if m < 60 { return sec == 0 ? "\(m) min" : "\(m) min \(sec) s" }
        return "\(m / 60) h \(m % 60) min"
    }
}

enum GitBranch {
    /// The current branch of the repository containing `cwd` (looks a few folders up), or nil.
    static func read(from cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        var url = URL(fileURLWithPath: cwd)
        for _ in 0..<5 {
            let head = url.appendingPathComponent(".git/HEAD")
            if let text = try? String(contentsOf: head, encoding: .utf8) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("ref: refs/heads/") { return String(t.dropFirst("ref: refs/heads/".count)) }
                return String(t.prefix(7))      // detached head: short hash
            }
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return nil
    }
}
