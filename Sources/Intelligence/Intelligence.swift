import Foundation
import FoundationModels

enum NotificationPriority: String {
    case now, later, noise
}

struct TriageResult: Equatable {
    let priority: NotificationPriority
    let summary: String
}

@Generable
struct TriageOutput {
    @Guide(description: "Priority", .anyOf(["noise", "later", "now"]))
    var priority: String
    @Guide(description: "Under 10 words, plain language")
    var summary: String
}

@Generable
struct ReplyOptions {
    @Guide(description: "Three different short replies the user could send, each under 12 words, in the same language as the message", .count(3))
    var replies: [String]
}

/// Apple Intelligence on this Mac: private, free, no network. Everything here fails soft:
/// when the model is not available the app simply shows its plain-rule version.
enum Intelligence {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// One short plain sentence about what a Claude Code request will do.
    static func explain(tool: String, headline: String, detail: String) async -> String? {
        guard isAvailable else { return nil }
        return await withTimeout(6) {
            let session = LanguageModelSession(instructions: """
                You explain what a computer action requested by a coding assistant will do, for someone who does not code.
                Answer with ONE short sentence of at most 14 words that starts with a verb such as Saves, Deletes, Downloads, Changes, Reads, Runs, Installs, Uploads.
                No quotes, no code, no markdown, no preamble.
                """)
            let prompt = "Action type: \(headline)\nTool: \(tool)\nDetails: \(detail.prefix(600))"
            guard let reply = try? await session.respond(to: prompt) else { return nil }
            return clean(reply.content)
        }
    }

    /// Sorts a notification into now / later / noise with a very short summary.
    static func triage(_ raw: RawNotification, appName: String) async -> TriageResult? {
        guard isAvailable else { return nil }
        return await withTimeout(3) {
            let session = LanguageModelSession(instructions: """
                You sort Mac notifications for one person. Choose exactly one priority.
                now: a person is waiting for an answer, a money or security problem, a deadline today.
                later: useful information that needs no action today (deliveries, finished jobs, chat messages).
                noise: counts, likes, promotions, newsletters, automatic status.
                Examples: "Bank: payment declined" = now. "Mum: need to know by 5" = now. "Amazon: package delivered" = later. "Instagram: 20 likes" = noise.
                """)
            let parts = [raw.title, raw.subtitle, raw.body].compactMap { $0 }.filter { !$0.isEmpty }
            let prompt = "\(appName): " + parts.joined(separator: " - ").prefix(500)
            guard let r = try? await session.respond(to: prompt, generating: TriageOutput.self) else { return nil }
            guard let p = NotificationPriority(rawValue: r.content.priority) else { return nil }
            return TriageResult(priority: p, summary: clean(r.content.summary))
        }
    }

    /// Three short replies to a message, written the way the user writes (their own earlier messages in the
    /// same chat are the examples). Only suggestions: the user picks, edits and sends them.
    static func suggestReplies(to message: String, from sender: String, myEarlier: [String]) async -> [String] {
        guard isAvailable, !message.isEmpty else { return [] }
        let style = myEarlier.isEmpty ? "" : "\nHow this person usually writes to \(sender) (match the tone, length and casing, not the content):\n"
            + myEarlier.prefix(8).map { "- \($0)" }.joined(separator: "\n")
        return await withTimeout(8) {
            let session = LanguageModelSession(instructions: """
                You suggest quick replies to a text message for the person who received it. Write as that person, \
                in the first person, casual and natural. Three different options: for example a yes, a no or later, \
                and a question back. No greetings unless the message has one, no emoji unless their style uses them, \
                no quotes around the replies.
                """)
            let prompt = "Message from \(sender): \(message.prefix(600))" + style
            guard let r = try? await session.respond(to: prompt, generating: ReplyOptions.self) else { return nil }
            return r.content.replies.map(clean).filter { !$0.isEmpty }
        } ?? []
    }

    /// A short summary of any amount of text: long texts are summarised piece by piece, then together.
    static func summarize(_ text: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> String? {
        guard isAvailable else { return nil }
        let chunkSize = 3500
        func pieces(_ s: String) -> [String] {
            var out: [String] = [], current = ""
            for para in s.components(separatedBy: "\n") {
                if current.count + para.count > chunkSize, !current.isEmpty { out.append(current); current = "" }
                var p = para
                while p.count > chunkSize { out.append(String(p.prefix(chunkSize))); p = String(p.dropFirst(chunkSize)) }
                current += (current.isEmpty ? "" : "\n") + p
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        func one(_ s: String, final: Bool) async -> String? {
            await withTimeout(40) {
                let session = LanguageModelSession(instructions: final ? """
                    You summarize text for a busy person. Write the main point in one sentence, then at most five short bullet points starting with "- ".
                    Plain language, no markdown formatting other than the dashes, no preamble. Use the same language as the text.
                    """ : """
                    Summarize this part of a longer text in at most three sentences. Plain language. Use the same language as the text.
                    """)
                guard let r = try? await session.respond(to: s) else { return nil }
                return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var round = 0
        while current.count > chunkSize, round < 4 {
            let parts = pieces(current)
            var summaries: [String] = []
            for (i, p) in parts.enumerated() {
                guard let s = await one(p, final: false) else { return nil }
                summaries.append(s)
                progress(min(0.9, (Double(i + 1) / Double(parts.count)) * (0.9 / Double(round + 1))))
            }
            current = summaries.joined(separator: "\n")
            round += 1
        }
        let result = await one(current, final: true)
        progress(1)
        return result
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        while t.hasPrefix("\"") || t.hasPrefix("'") { t.removeFirst() }
        while t.hasSuffix("\"") || t.hasSuffix("'") { t.removeLast() }
        return t.count > 120 ? String(t.prefix(117)) + "..." : t
    }

    /// For answers to questions about a file: tidied but never shortened, paragraphs kept.
    /// (`clean` is for one-line summaries and cuts at 120 characters.)
    static func cleanAnswer(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        while t.hasPrefix("\"") { t.removeFirst() }
        while t.hasSuffix("\"") { t.removeLast() }
        return t
    }

    private static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Is a Focus mode (such as Do Not Disturb) switched on right now?
enum FocusState {
    static func isOn(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        let url = home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stores = obj["data"] as? [[String: Any]] else { return false }
        return stores.contains { !(($0["storeAssertionRecords"] as? [Any]) ?? []).isEmpty }
    }
}
