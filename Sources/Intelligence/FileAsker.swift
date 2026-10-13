import Foundation
import FoundationModels
import ImageIO

/// One question about one file, with the answers that came before (so follow-ups make sense).
struct AskTurn: Identifiable, Equatable {
    let id = UUID()
    let question: String
    var answer: String = ""
    var failed = false
    var finished = false
    /// What is happening before the answer starts (for audio and video: the transcription).
    var status: String = ""
}

/// What the answering engine is given for one question.
struct AskRequest: Sendable {
    let url: URL
    let kind: FileKind
    let question: String
    /// Earlier questions and answers, oldest first.
    let history: [(question: String, answer: String)]
    /// The words of an audio or video file, once transcribed.
    var text: String? = nil
}

/// Ask questions about a file you parked on the shelf. Everything runs on this Mac by default.
@MainActor
final class FileAsker: ObservableObject {
    @Published private(set) var turns: [AskTurn] = []
    @Published private(set) var busy = false
    let url: URL
    let kind: FileKind
    /// Replaced in tests. Yields the growing answer text; throws a plain-words error.
    var engine: (AskRequest) -> AsyncThrowingStream<String, Error> = { Intelligence.answerAboutFile($0) }
    /// Turns audio or video into words. Replaced in tests; the real one writes no files.
    var transcriber: (URL, @escaping @Sendable (String) -> Void) async throws -> String = { url, report in
        try await Speech.transcriptText(url, language: FileActions.defaultSpeechLanguage) { p in
            report(p.fraction.map { "Listening… \(Int($0 * 100))%" } ?? p.status)
        }
    }
    /// The words of the file, kept after the first time so follow-ups answer at once.
    private(set) var transcript: String?
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        self.kind = FileKind.of(url)
    }

    /// Files this can be asked about: pictures, PDFs, text files, and audio and video (through a transcript).
    static func canAsk(_ kind: FileKind) -> Bool { kind != .other }
    var needsTranscript: Bool { kind == .audio || kind == .video }

    func ask(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        let history = turns.filter { $0.finished && !$0.failed }.suffix(3).map { (question: $0.question, answer: $0.answer) }
        turns.append(AskTurn(question: q))
        let index = turns.count - 1
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if self.needsTranscript, self.transcript == nil {
                    self.turns[index].status = "Listening…"
                    let words = try await self.transcriber(self.url) { s in
                        Task { @MainActor [weak self] in
                            if let self, index < self.turns.count, self.turns[index].answer.isEmpty, !self.turns[index].finished { self.turns[index].status = s }
                        }
                    }
                    self.transcript = words
                }
                if index < self.turns.count { self.turns[index].status = "" }
                let request = AskRequest(url: self.url, kind: self.kind, question: q, history: history, text: self.transcript)
                for try await text in self.engine(request) {
                    guard index < self.turns.count else { return }
                    self.turns[index].answer = text
                }
                self.finish(index, failed: false)
            } catch {
                self.fail(index, error.localizedDescription)
            }
        }
    }

    private func finish(_ i: Int, failed: Bool) {
        guard i < turns.count else { return }
        if turns[i].answer.isEmpty { fail(i, "There was no answer. Try asking it another way."); return }
        turns[i].finished = true
        turns[i].status = ""
        busy = false
    }

    private func fail(_ i: Int, _ message: String) {
        guard i < turns.count else { return }
        turns[i].answer = message
        turns[i].failed = true
        turns[i].finished = true
        turns[i].status = ""
        busy = false
    }

    func stop() { task?.cancel(); busy = false }
    func clear() { task?.cancel(); turns = []; busy = false }
    var lastAnswer: String? { turns.last(where: { $0.finished && !$0.failed })?.answer }
}

// MARK: - The real engine (Apple Intelligence on this Mac)

extension Intelligence {
    /// About 3 characters to a token is safe for English and for other scripts alike.
    static let charsPerToken = 3

    private static let rules = """
        You answer questions about one file the owner gave you. Use ONLY what the file says. If the file does not say, answer exactly: "That isn't in this file."
        Be brief and direct: one to three short sentences, or a short list when asked for several things. No preamble, no markdown headings.
        Quote numbers, names and dates exactly as written. Answer in the language of the question.
        """

    static func answerAboutFile(_ r: AskRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    guard isAvailable else { throw ActionError(message: "Apple Intelligence isn't available on this Mac right now.") }
                    if r.kind == .image {
                        try await answerAboutImage(r, into: continuation)
                    } else {
                        try await answerAboutText(r, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: friendly(error))
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func friendly(_ error: Error) -> Error {
        if error is ActionError { return error }
        let text = String(describing: error).lowercased()
        if text.contains("guardrail") { return ActionError(message: "Apple Intelligence declined to answer that one.") }
        if text.contains("language") { return ActionError(message: "Apple Intelligence doesn't support the language of that question yet.") }
        if text.contains("context") { return ActionError(message: "That file is too big to read in one go. Ask something more specific.") }
        return ActionError(message: "Couldn't get an answer right now. Try again in a moment.")
    }

    private static func historyText(_ h: [(question: String, answer: String)]) -> String {
        h.isEmpty ? "" : "Earlier in this conversation:\n" + h.map { "Q: \($0.question)\nA: \($0.answer.prefix(500))" }.joined(separator: "\n") + "\n\n"
    }

    /// Text and PDFs: the whole file when it fits, otherwise the parts that match the question.
    private static func answerAboutText(_ r: AskRequest, into out: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let full: String
        if let preloaded = r.text { full = preloaded } else { full = try await Texts.read(r.url) { _ in } }
        guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActionError(message: r.kind == .pdf ? "No text was found in this PDF." : (r.kind == .audio || r.kind == .video ? "No speech was found in this file." : "This file has no text to ask about."))
        }
        var budget = 14_000      // characters of the file, out of an 8,000 token window
        for attempt in 0..<3 {
            let chunks = TextChunker.split(full)
            let picked = TextChunker.relevant(chunks, to: r.question, budget: budget)
            let excerpt = picked.joined(separator: "\n[…]\n")
            let spoken = (r.kind == .audio || r.kind == .video) ? "This is a transcript of the speech in the file.\n" : ""
            let note = spoken + (picked.count < chunks.count ? "These are only the parts of the file that look relevant to the question.\n" : "")
            let session = LanguageModelSession(instructions: rules)
            let prompt = "\(note)File: \(r.url.lastPathComponent)\n---\n\(excerpt)\n---\n\n\(historyText(r.history))Question: \(r.question)"
            do {
                for try await partial in session.streamResponse(to: prompt) { out.yield(clean(partial.content)) }
                return
            } catch {
                if String(describing: error).lowercased().contains("context"), attempt < 2 { budget /= 2; continue }
                throw error
            }
        }
    }

    /// Pictures: the model looks at the picture itself (macOS 27); on older systems it reads the text in it.
    private static func answerAboutImage(_ r: AskRequest, into out: AsyncThrowingStream<String, Error>.Continuation) async throws {
        if #available(macOS 27.0, *) {
            let session = LanguageModelSession(instructions: rules)
            let prompt = Prompt {
                historyText(r.history) + "Question: " + r.question
                Attachment(imageURL: r.url)
            }
            for try await partial in session.streamResponse(to: prompt) { out.yield(clean(partial.content)) }
        } else {
            let text = try await Task.detached { try Images.recognize(try Images.loadCGImage(r.url)) }.value
            guard !text.isEmpty else { throw ActionError(message: "This version of macOS can only read the text in a picture, and none was found.") }
            let session = LanguageModelSession(instructions: rules)
            let prompt = "Text read from the picture \(r.url.lastPathComponent):\n---\n\(text.prefix(14_000))\n---\n\n\(historyText(r.history))Question: \(r.question)"
            for try await partial in session.streamResponse(to: prompt) { out.yield(clean(partial.content)) }
        }
    }
}
