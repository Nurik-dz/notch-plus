import Foundation
import CryptoKit
import Translation
import NaturalLanguage

// Small pieces the copied speech engine needs (from the Studio apps), plus translation.

/// One recognized word with its timing.
struct TranscribedWord: Codable, Hashable, Sendable {
    /// Includes the whitespace the recognizer put around the token, so words
    /// rebuild into text by plain concatenation.
    var text: String
    var start: Double
    var end: Double
    var confidence: Double?
}

enum Timecode {
    /// Clock-style display: "1:02:03", or "2:03" under an hour.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum LanguageCatalog {
    /// "English (United States)" for "en-US".
    static func name(for code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Where unfinished long transcriptions are kept so a quit costs at most one window.
enum ProjectStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchPlus/Work", isDirectory: true)
    }

    static func key(for media: URL) -> String {
        let digest = SHA256.hash(data: Data(media.standardizedFileURL.path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func location(for media: URL) -> URL {
        directory.appendingPathComponent(key(for: media) + ".json")
    }
}

/// Apple's on-device translation between any two installed languages.
enum Translator {
    /// Languages offered in menus (all available for translation on macOS 27).
    static let languages: [(id: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("nl", "Dutch"), ("pl", "Polish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"),
        ("ar", "Arabic"), ("he", "Hebrew"), ("hi", "Hindi"), ("id", "Indonesian"),
        ("th", "Thai"), ("vi", "Vietnamese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]

    static func name(_ id: String) -> String { languages.first { $0.id == id }?.name ?? id }

    struct NotInstalled: LocalizedError {
        var language: String
        var errorDescription: String? {
            "\(Translator.name(language)) isn't installed for translation. Add it in System Settings > General > Language & Region > Translation Languages, then try again."
        }
    }

    /// The language a text is written in ("en", "ru"...), or nil when unsure.
    static func detect(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(2000)))
        return r.dominantLanguage.map { $0.rawValue.components(separatedBy: "-").first ?? $0.rawValue }
    }

    /// Translates `texts` and hands back each result in order.
    static func translate(_ texts: [String], from source: String, to target: String,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let src = Locale.Language(identifier: source), dst = Locale.Language(identifier: target)
        guard source != target else { return texts }
        let availability = await LanguageAvailability().status(from: src, to: dst)
        guard availability == .installed else {
            throw NotInstalled(language: availability == .unsupported ? source : target)
        }
        let session = TranslationSession(installedSource: src, target: dst)
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        var out = texts
        var done = 0
        for try await response in session.translate(batch: requests) {
            try Task.checkCancellation()
            if let i = response.clientIdentifier.flatMap(Int.init) { out[i] = response.targetText }
            done += 1
            progress(Double(done) / Double(texts.count))
        }
        return out
    }
}
