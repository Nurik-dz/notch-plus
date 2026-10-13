import Foundation
import Speech
import AVFoundation

struct ProgressUpdate: Sendable {
    var fraction: Double? = nil
    var status: String? = nil
    var snippet: String? = nil
    /// How far into the recording the recognizer has heard, in seconds.
    var position: Double? = nil
}

typealias ProgressHandler = @Sendable (ProgressUpdate) -> Void

/// Speech-to-text over files of any length.
///
/// Long recordings are transcribed as a sequence of windows rather than one
/// analyzer run over one enormous temp file. That bounds temp disk use, limits
/// a failure to one window (which is retried) instead of the rest of the file,
/// and makes progress honest. Each window decodes extra audio on both sides so
/// the recognizer has context across a seam, but only words inside the
/// committed range are kept, so nothing is emitted twice.
enum SpeechEngine {
    struct Result: Sendable {
        var words: [TranscribedWord]
        /// Set when the run finished but couldn't cover the whole recording.
        var warning: String?
    }

    private static let windowLength: Double = 900
    private static let contextPadding: Double = 10
    private static let boundarySnapRadius: Double = 3
    private static let windowingThreshold: Double = 1200
    /// How long before a seam a window's words are held back, so they can be
    /// joined to the next window where both heard the same words.
    private static let tailLength: Double = 5

    /// Progress of a long transcription, saved after every finished window so
    /// a quit, crash or restart costs at most one window instead of the whole recording.
    struct Checkpoint: Codable {
        struct Failure: Codable { var start: Double; var end: Double; var reason: String }
        var languageCode: String
        var duration: Double
        var windowLength: Double
        var nextIndex: Int
        var acceptFrom: Double
        var words: [TranscribedWord]
        var failures: [Failure]
        /// The last window's words near its end, not yet joined to the next.
        var tail: [TranscribedWord]? = nil

        static func location(for url: URL) -> URL {
            ProjectStore.location(for: url).deletingPathExtension().appendingPathExtension("partial.json")
        }

        static func load(for url: URL) -> Checkpoint? {
            guard let data = try? Data(contentsOf: location(for: url)) else { return nil }
            return try? JSONDecoder().decode(Checkpoint.self, from: data)
        }

        func save(for url: URL) {
            try? FileManager.default.createDirectory(at: ProjectStore.directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(self) { try? data.write(to: Checkpoint.location(for: url), options: .atomic) }
        }

        static func delete(for url: URL) {
            try? FileManager.default.removeItem(at: location(for: url))
        }

        /// Where an unfinished run for this language stopped, if any.
        static func resumePoint(for url: URL, languageCode: String) -> Double? {
            guard let checkpoint = load(for: url), checkpoint.languageCode == languageCode, checkpoint.nextIndex > 0 else { return nil }
            return Double(checkpoint.nextIndex) * checkpoint.windowLength
        }
    }

    static func transcribe(
        url: URL,
        languageCode: String,
        vocabulary: [String],
        resume: Bool = true,
        update: @escaping ProgressHandler
    ) async throws -> Result {
        update(ProgressUpdate(fraction: 0.01, status: "Reading media…"))
        let duration = try await MediaInfo.load(url).duration
        let locale = Locale(identifier: languageCode)

        // The on-device transcriber covers a subset of languages. Others go
        // through SFSpeechRecognizer, which recognizes on Apple's servers.
        let onDevice = await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
        if onDevice {
            try await prepareOnDeviceModel(locale: locale, update: update)
        } else {
            try await prepareServerRecognizer(locale: locale, update: update)
        }

        let isWindowed = duration > windowingThreshold
        let commitLength = isWindowed ? windowLength : duration
        // The 0.5s slack stops a duration a hair over a multiple of the window
        // length from spawning a near-empty extra window.
        let windowCount = max(1, Int(ceil((duration - 0.5) / commitLength)))

        var allWords: [TranscribedWord] = []
        var acceptFrom: Double = 0
        var tail: [TranscribedWord] = []
        var failures: [(start: Double, end: Double, reason: String)] = []
        var firstIndex = 0

        if !resume { Checkpoint.delete(for: url) }
        if isWindowed, resume, let saved = Checkpoint.load(for: url),
           saved.languageCode == languageCode, saved.windowLength == windowLength,
           abs(saved.duration - duration) < 1, saved.nextIndex < windowCount {
            firstIndex = saved.nextIndex
            allWords = saved.words
            acceptFrom = saved.acceptFrom
            tail = saved.tail ?? []
            failures = saved.failures.map { ($0.start, $0.end, $0.reason) }
            update(ProgressUpdate(status: "Continuing from \(Timecode.clock(Double(firstIndex) * commitLength))…"))
        }

        for index in firstIndex..<windowCount {
            try Task.checkCancellation()

            let isLast = index == windowCount - 1
            let nominalStart = Double(index) * commitLength
            let nominalEnd = isLast ? duration : min(duration, nominalStart + commitLength)
            let audioStart = max(0, nominalStart - contextPadding)
            let audioEnd = min(duration, nominalEnd + contextPadding)
            let audioLength = audioEnd - audioStart
            guard audioLength > 0.25 else { continue }

            update(ProgressUpdate(
                fraction: 0.08 + 0.9 * Double(index) / Double(windowCount),
                status: isWindowed
                    ? "Part \(index + 1) of \(windowCount): \(Timecode.clock(nominalStart)) to \(Timecode.clock(nominalEnd))"
                    : (onDevice ? "Listening on this Mac…" : "Listening with Apple's online recognizer…")
            ))

            var windowWords: [TranscribedWord]?
            var lastError: Error?
            for attempt in 0..<2 {
                if attempt > 0 {
                    update(ProgressUpdate(status: "Retrying \(Timecode.clock(nominalStart)) to \(Timecode.clock(nominalEnd))…"))
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                do {
                    // Live progress inside the window, from what has been heard.
                    let windowUpdate: ProgressHandler = { progress in
                        var progress = progress
                        if let heard = progress.position {
                            let at = min(audioEnd, audioStart + heard)
                            progress.position = at
                            progress.fraction = 0.08 + 0.9 * min(1, at / max(duration, 1))
                        }
                        update(progress)
                    }
                    windowWords = try await transcribeWindow(
                        url: url,
                        audioStart: audioStart,
                        audioLength: audioLength,
                        expectFullLength: audioEnd < duration - 0.5,
                        locale: locale,
                        vocabulary: vocabulary,
                        onDevice: onDevice,
                        update: windowUpdate
                    )
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            try Task.checkCancellation()

            guard var words = windowWords else {
                // Record the hole and keep going: a failure at hour three must
                // not cost hours four through twelve.
                failures.append((nominalStart, nominalEnd, lastError?.localizedDescription ?? "unknown error"))
                allWords += tail
                tail = []
                acceptFrom = nominalEnd
                if isWindowed && !isLast {
                    Checkpoint(
                        languageCode: languageCode, duration: duration, windowLength: windowLength,
                        nextIndex: index + 1, acceptFrom: acceptFrom, words: allWords,
                        failures: failures.map { Checkpoint.Failure(start: $0.start, end: $0.end, reason: $0.reason) },
                        tail: tail
                    ).save(for: url)
                }
                continue
            }

            for i in words.indices {
                words[i].start += audioStart
                words[i].end += audioStart
            }
            words.sort { $0.start < $1.start }

            var fresh: [TranscribedWord]
            if tail.isEmpty {
                fresh = words.filter { $0.start >= acceptFrom - 0.001 }
            } else {
                let joined = join(tail, to: words, at: nominalStart)
                allWords += joined.kept
                fresh = joined.rest
                tail = []
            }
            if isLast {
                allWords += fresh
                acceptFrom = nominalEnd
            } else {
                let holdFrom = nominalEnd - tailLength
                allWords += fresh.filter { $0.start < holdFrom }
                tail = fresh.filter { $0.start >= holdFrom }
                acceptFrom = tail.first?.start ?? holdFrom
            }

            if isWindowed && !isLast {
                Checkpoint(
                    languageCode: languageCode, duration: duration, windowLength: windowLength,
                    nextIndex: index + 1, acceptFrom: acceptFrom, words: allWords,
                    failures: failures.map { Checkpoint.Failure(start: $0.start, end: $0.end, reason: $0.reason) },
                    tail: tail
                ).save(for: url)
            }
        }
        allWords += tail

        update(ProgressUpdate(fraction: 0.99, status: "Building lines…"))
        Checkpoint.delete(for: url)

        guard !allWords.isEmpty else {
            if let first = failures.first {
                throw FFmpeg.Failure(message: "Speech recognition failed: \(first.reason)")
            }
            throw FFmpeg.Failure(message: "No speech was found in this file.")
        }
        return Result(words: allWords, warning: coverageWarning(words: allWords, failures: failures, duration: duration))
    }

    // MARK: - Windows

    /// Joins the end of one window to the next where both heard the same two
    /// words in a row, by position in the text rather than by time. The two
    /// recognitions time the same word a few hundredths of a second apart, so
    /// a cut at an exact time dropped the word on the seam whenever the next
    /// window timed it a hair earlier ("for one hour. is all that I have").
    private static func join(_ tail: [TranscribedWord], to next: [TranscribedWord], at seam: Double) -> (kept: [TranscribedWord], rest: [TranscribedWord]) {
        let a = tail.map { normalized($0.text) }
        let b = next.map { normalized($0.text) }
        var best: (i: Int, j: Int, distance: Double)?
        for i in 0..<max(0, a.count - 1) where !a[i].isEmpty {
            for j in 0..<max(0, b.count - 1) where b[j] == a[i] && b[j + 1] == a[i + 1] && abs(next[j].start - tail[i].start) < 0.6 {
                let distance = abs(tail[i].start - seam)
                if best == nil || distance < best!.distance { best = (i, j, distance) }
            }
        }
        if let best {
            return (Array(tail[...best.i]), Array(next[(best.j + 1)...]))
        }
        let cut = seamCut(near: seam, in: tail)
        return (tail.filter { $0.start < cut }, next.filter { $0.start >= cut })
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A time to cut at when the two windows share no words: the middle of the
    /// widest pause just after the seam, else the middle of the first word
    /// after it, so timing differences between the windows can't push that
    /// word out of both. If the window ran out of words before the seam, the
    /// next window takes over from its last word.
    private static func seamCut(near nominal: Double, in words: [TranscribedWord]) -> Double {
        guard let last = words.last else { return nominal }
        if last.end < nominal { return last.end }
        var bestGap: Double = 0
        var bestCut: Double?
        for i in 0..<(words.count - 1) {
            let gapStart = words[i].end
            let gapEnd = words[i + 1].start
            let midpoint = (gapStart + gapEnd) / 2
            guard midpoint >= nominal, midpoint <= nominal + boundarySnapRadius else { continue }
            if gapEnd - gapStart > bestGap {
                bestGap = gapEnd - gapStart
                bestCut = midpoint
            }
        }
        if let bestCut, bestGap > 0.2 { return bestCut }
        if let next = words.first(where: { $0.start >= nominal }) { return (next.start + next.end) / 2 }
        return nominal
    }

    private static func transcribeWindow(
        url: URL,
        audioStart: Double,
        audioLength: Double,
        expectFullLength: Bool,
        locale: Locale,
        vocabulary: [String],
        onDevice: Bool,
        update: @escaping ProgressHandler
    ) async throws -> [TranscribedWord] {
        let segment = try await AudioExtractor.extract(from: url, start: audioStart, duration: audioLength)
        defer { try? FileManager.default.removeItem(at: segment) }

        guard let file = try? AVAudioFile(forReading: segment) else {
            throw FFmpeg.Failure(message: "Couldn't read the extracted audio.")
        }

        // Never trust a decode to be complete: a short read mid-file is a
        // retry, not a silent gap. A window ending at EOF may legitimately
        // come up a beat short (encoder padding), so only check mid-file.
        let decoded = Double(file.length) / file.fileFormat.sampleRate
        if expectFullLength && decoded < audioLength - 2 {
            throw FFmpeg.Failure(message: "Audio decode returned \(Timecode.clock(decoded)) instead of \(Timecode.clock(audioLength)).")
        }

        if onDevice {
            return try await transcribeOnDevice(file: file, locale: locale, vocabulary: vocabulary, update: update)
        }
        return try await transcribeOnServer(url: segment, locale: locale, update: update)
    }

    private static func coverageWarning(words: [TranscribedWord], failures: [(start: Double, end: Double, reason: String)], duration: Double) -> String? {
        var notes: [String] = []
        if !failures.isEmpty {
            let list = failures.prefix(6).map { "\(Timecode.clock($0.start)) to \(Timecode.clock($0.end))" }.joined(separator: ", ")
            let more = failures.count > 6 ? " and \(failures.count - 6) more" : ""
            notes.append("Recognition failed on \(failures.count) section\(failures.count == 1 ? "" : "s"), which were skipped: \(list)\(more).\n\nReason: \(failures[0].reason)")
        }
        // A transcript that stops before halfway is the signature of a
        // truncated decode, not of a quiet second half.
        if let lastEnd = words.last?.end, duration > 60, lastEnd < duration * 0.5 {
            notes.append("Lines end at \(Timecode.clock(lastEnd)) but the recording runs to \(Timecode.clock(duration)). The audio may not have decoded in full.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }

    // MARK: - On-device engine

    private static func prepareOnDeviceModel(locale: Locale, update: ProgressHandler) async throws {
        update(ProgressUpdate(fraction: 0.03, status: "Loading the speech model…"))
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                update(ProgressUpdate(fraction: 0.05, status: "Downloading the \(LanguageCatalog.name(for: locale.identifier(.bcp47))) speech model (one time)…"))
                try await request.downloadAndInstall()
            }
        } catch {
            throw FFmpeg.Failure(message: "Couldn't prepare the speech model: \(error.localizedDescription)")
        }
    }

    private static func transcribeOnDevice(
        file: AVAudioFile,
        locale: Locale,
        vocabulary: [String],
        update: @escaping ProgressHandler
    ) async throws -> [TranscribedWord] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        // No voice-activity gating on purpose: it drops quiet lines (soft
        // narration, asides, speech under music). The recognizer decides.
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }

        let collector = WordCollector()
        let resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = result.text
                    let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !plain.isEmpty {
                        let heard = result.range.end.seconds
                        update(ProgressUpdate(snippet: String(plain.suffix(90)), position: heard.isFinite ? heard : nil))
                    }
                    guard result.isFinal else { continue }
                    for run in text.runs {
                        let raw = String(text[run.range].characters)
                        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        if let range = run.audioTimeRange {
                            collector.append(TranscribedWord(
                                text: raw,
                                start: range.start.seconds,
                                end: (range.start + range.duration).seconds,
                                confidence: run.transcriptionConfidence
                            ))
                        } else {
                            // Untimed runs (punctuation) join the previous word
                            // rather than being dropped.
                            collector.appendToLast(raw)
                        }
                    }
                }
            } catch {
                collector.recordFailure(error)
            }
        }

        do {
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            resultsTask.cancel()
            try Task.checkCancellation()
            throw FFmpeg.Failure(message: "Speech analysis failed: \(error.localizedDescription)")
        }

        await resultsTask.value
        try Task.checkCancellation()
        if let failure = collector.failure {
            throw FFmpeg.Failure(message: "The speech results stream failed: \(failure.localizedDescription)")
        }
        return collector.words
    }

    private final class WordCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TranscribedWord] = []
        private var error: Error?

        func append(_ word: TranscribedWord) {
            lock.lock(); defer { lock.unlock() }
            storage.append(word)
        }

        func appendToLast(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            guard !storage.isEmpty else { return }
            storage[storage.count - 1].text += text
        }

        func recordFailure(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            if self.error == nil { self.error = error }
        }

        var words: [TranscribedWord] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        var failure: Error? {
            lock.lock(); defer { lock.unlock() }
            return error
        }
    }

    // MARK: - Server engine (languages the on-device model doesn't cover)

    private static func prepareServerRecognizer(locale: Locale, update: ProgressHandler) async throws {
        update(ProgressUpdate(fraction: 0.03, status: "Requesting speech recognition permission…"))
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw FFmpeg.Failure(message: "Speech Recognition permission was denied. Turn it on in System Settings > Privacy & Security > Speech Recognition, then try again.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw FFmpeg.Failure(message: "Speech recognition for \(LanguageCatalog.name(for: locale.identifier(.bcp47))) isn't available right now. Check your internet connection.")
        }
    }

    private static func transcribeOnServer(url: URL, locale: Locale, update: @escaping ProgressHandler) async throws -> [TranscribedWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw FFmpeg.Failure(message: "Speech recognition isn't available right now. Check your internet connection.")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            var task: SFSpeechRecognitionTask?
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let once = Once()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let plain = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !plain.isEmpty { update(ProgressUpdate(snippet: String(plain.suffix(90)))) }
                        if result.isFinal, once.claim() {
                            // Segments are bare words, so a separator is added back.
                            let words = result.bestTranscription.segments.map {
                                TranscribedWord(text: $0.substring + " ", start: $0.timestamp, end: $0.timestamp + $0.duration, confidence: Double($0.confidence))
                            }
                            continuation.resume(returning: words)
                        }
                    }
                    if let error, once.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            once.task?.cancel()
        }
    }
}
