import Foundation

enum Risk: Int, Comparable {
    case low, medium, high
    static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
}

/// Turns a raw Claude Code tool request into plain words and a risk level.
/// General rules only; the on-device model adds a richer explanation later.
enum RequestDescriber {
    static func describe(tool: String, input: [String: Any]) -> (headline: String, detail: String, risk: Risk) {
        func text(_ keys: String...) -> String {
            for k in keys { if let s = input[k] as? String, !s.isEmpty { return s } }
            return ""
        }
        switch tool {
        case "Bash":
            let cmd = text("command")
            let risk = bashRisk(cmd)
            let headline = risk == .low ? "Run a read-only command" : risk == .high ? "Run a risky command" : "Run a command"
            return (headline, cmd, risk)
        case "Read", "Glob", "Grep", "LS":
            return ("Read files", text("file_path", "pattern", "path"), .low)
        case "Edit", "MultiEdit", "NotebookEdit", "Write":
            let path = text("file_path", "notebook_path")
            return (tool == "Write" ? "Write a file" : "Change a file", path, isSensitivePath(path) ? .high : .medium)
        case "WebFetch":
            return ("Open a web page", text("url"), .medium)
        case "WebSearch":
            return ("Search the web", text("query"), .low)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                let readable = parts.joined(separator: " / ").replacingOccurrences(of: "_", with: " ")
                return ("Use a connected tool", readable, .medium)
            }
            return ("Use \(tool)", text("command", "file_path", "url", "query"), .medium)
        }
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let p = path.lowercased()
        return ["/.ssh/", "/.aws/", "/.gnupg/", "/etc/", "/library/launchagents", "/library/launchdaemons",
                ".zshrc", ".zprofile", ".bashrc", ".bash_profile", "/.env", "id_rsa", "/.claude/settings"]
            .contains { p.contains($0) }
    }

    private static let riskyPatterns: [String] = [
        #"\brm\s+-[a-z]*[rf]"#, #"\bsudo\b"#, #"\bdd\s+if="#, #"\bmkfs"#, #"\bchmod\s+-R"#, #"\bchown\s+-R"#,
        #"\bgit\s+push\b.*(--force|\s-f\b)"#, #"\bgit\s+reset\s+--hard"#, #"\bgit\s+clean\s+-[a-z]*f"#,
        #"(curl|wget)[^|]*\|\s*(sudo\s+)?(ba|z)?sh"#, #">\s*/dev/"#, #":\(\)\s*\{"#, #"\bkill(all)?\s+-9"#,
        #"\b(shutdown|reboot)\b"#, #"\bdiskutil\s+(erase|partition)"#, #"\bsecurity\s+(delete|dump)"#,
        #"\.ssh/|\.aws/|\.gnupg/|\.env\b|id_rsa"#,
    ]

    private static let readOnlyWords: Set<String> = [
        "ls", "cat", "pwd", "echo", "head", "tail", "wc", "grep", "rg", "which", "whoami", "date", "file",
        "stat", "du", "df", "tree", "sort", "uniq", "basename", "dirname", "env", "uname", "sw_vers",
    ]
    private static let readOnlyGit: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "rev-parse"]

    static func bashRisk(_ cmd: String) -> Risk {
        for p in riskyPatterns where cmd.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
            return .high
        }
        if cmd.contains(">") || cmd.contains("<") || cmd.contains("`") || cmd.contains("$(") { return .medium }
        let segments = cmd.replacingOccurrences(of: "&&", with: "|").replacingOccurrences(of: "||", with: "|")
            .replacingOccurrences(of: ";", with: "|").components(separatedBy: "|")
        guard !segments.isEmpty else { return .medium }
        for seg in segments {
            let words = seg.split(separator: " ").map(String.init)
            guard let first = words.first else { return .medium }
            if first == "git" {
                guard words.count > 1, readOnlyGit.contains(words[1]) else { return .medium }
            } else if first == "find" {
                if seg.contains("-delete") || seg.contains("-exec") { return .medium }
            } else if !readOnlyWords.contains(first) {
                return .medium
            }
        }
        return .low
    }
}
