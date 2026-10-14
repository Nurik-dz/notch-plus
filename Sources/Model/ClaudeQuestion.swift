import Foundation

/// One of Claude's own questions (its AskUserQuestion tool), as it arrives in the hook:
/// {"questions":[{"question","header","options":[{"label","description"}],"multiSelect"}]}.
/// Recorded from a real Claude Code session on 2026-10-13 (Docs/Roadmap.txt, item 2, PROBE RESULT).
struct ClaudeQuestion: Equatable, Identifiable {
    struct Option: Equatable, Identifiable {
        let label: String
        let description: String
        var id: String { label }
        /// Claude marks its suggestion by ending the label with "(Recommended)".
        var isRecommended: Bool { label.localizedCaseInsensitiveContains("(recommended)") }
        /// The label without the "(Recommended)" marker, for showing (the answer keeps the exact label).
        var title: String {
            label.replacingOccurrences(of: "(Recommended)", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    let question: String
    let header: String
    let options: [Option]
    let multiSelect: Bool
    var id: String { question }

    static func parse(_ input: [String: Any]) -> [ClaudeQuestion] {
        guard let list = input["questions"] as? [[String: Any]] else { return [] }
        return list.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
                guard let label = o["label"] as? String else { return nil }
                return Option(label: label, description: o["description"] as? String ?? "")
            }
            guard !options.isEmpty else { return nil }
            return ClaudeQuestion(question: text, header: q["header"] as? String ?? "",
                                  options: options, multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// What Claude Code expects back: the questions as they came, plus "answers" keyed by the question
    /// text (several picks joined with ", "), plus empty "annotations" (seen in its own PostToolUse record).
    static func updatedInput(original: [String: Any], questions: [ClaudeQuestion], picks: [String: [String]]) -> [String: Any] {
        var answers: [String: String] = [:]
        for q in questions {
            let chosen = q.options.map(\.label).filter { (picks[q.question] ?? []).contains($0) }
            if !chosen.isEmpty { answers[q.question] = chosen.joined(separator: ", ") }
        }
        var out = original
        out["answers"] = answers
        out["annotations"] = [String: Any]()
        return out
    }
}
