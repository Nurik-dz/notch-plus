import Foundation
import AppKit
import Vision
import PDFKit
import AVFoundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

enum FileKind: Hashable {
    case image, audio, video, pdf, text, other

    static func of(_ url: URL) -> FileKind {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .plainText) || t.conforms(to: .text) || t.conforms(to: .json) || ["md", "markdown", "srt", "vtt", "csv"].contains(url.pathExtension.lowercased()) { return .text }
        return .other
    }
}

struct ActionProgress: Sendable {
    var fraction: Double?
    var status: String
}
typealias ProgressSink = @Sendable (ActionProgress) -> Void

/// What an action produced: files saved next to the original, and often some text to show.
struct ActionResult: Sendable, Equatable {
    var title: String
    var files: [URL]
    var text: String?
}

struct FileAction: Identifiable, Hashable, Sendable {
    enum Group { case intelligence, convert }
    let id: String
    let title: String
    let symbol: String
    let group: Group
}

struct ActionMenu {
    var intelligence: [FileAction] = []
    var translate: [FileAction] = []            // "Translate to" (text, PDF) or "Transcribe and translate to" (audio, video)
    var translateTitle = "Translate to"
    var transcribeIn: [FileAction] = []         // "Transcribe in" other languages
    var convert: [FileAction] = []
    var isEmpty: Bool { intelligence.isEmpty && translate.isEmpty && convert.isEmpty && transcribeIn.isEmpty }
}

struct ActionError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum FileActions {
    /// Spoken languages offered for transcription (the first is this Mac's own language).
    static let speechLanguages: [(code: String, name: String)] = [
        ("en-US", "English"), ("ru-RU", "Russian"), ("ar-SA", "Arabic"), ("es-ES", "Spanish"), ("fr-FR", "French"),
        ("de-DE", "German"), ("it-IT", "Italian"), ("pt-BR", "Portuguese"), ("tr-TR", "Turkish"), ("uk-UA", "Ukrainian"),
        ("ja-JP", "Japanese"), ("ko-KR", "Korean"), ("zh-CN", "Chinese"),
    ]

    /// The menu for a kind of file.
    static func menu(for kind: FileKind) -> ActionMenu {
        var m = ActionMenu()
        let toLanguages = Translator.languages
        switch kind {
        case .image:
            m.intelligence = [
                FileAction(id: "removeBackground", title: "Remove background", symbol: "person.crop.rectangle", group: .intelligence),
                FileAction(id: "extractText", title: "Extract text", symbol: "text.viewfinder", group: .intelligence),
            ]
            m.convert = [
                FileAction(id: "image:png", title: "PNG", symbol: "photo", group: .convert),
                FileAction(id: "image:jpeg", title: "JPEG", symbol: "photo", group: .convert),
                FileAction(id: "image:heic", title: "HEIC", symbol: "photo", group: .convert),
                FileAction(id: "image:small", title: "Make smaller", symbol: "arrow.down.right.and.arrow.up.left", group: .convert),
            ]
        case .audio, .video:
            m.intelligence = [
                FileAction(id: "transcribe", title: "Transcribe", symbol: "text.bubble", group: .intelligence),
                FileAction(id: "summarize", title: "Summarize", symbol: "sparkles", group: .intelligence),
            ]
            m.transcribeIn = speechLanguages.map { FileAction(id: "transcribe:\($0.code)", title: $0.name, symbol: "globe", group: .intelligence) }
            m.translateTitle = "Transcribe and translate to"
            m.translate = toLanguages.map { FileAction(id: "transcribeTranslate:\($0.id)", title: $0.name, symbol: "globe", group: .intelligence) }
            m.convert = [
                FileAction(id: "audio:m4a", title: kind == .video ? "Extract audio (M4A)" : "M4A", symbol: "waveform", group: .convert),
                FileAction(id: "audio:wav", title: "WAV", symbol: "waveform", group: .convert),
            ]
        case .pdf, .text:
            m.intelligence = [
                FileAction(id: "summarize", title: "Summarize", symbol: "sparkles", group: .intelligence),
            ]
            if kind == .pdf { m.intelligence.insert(FileAction(id: "extractText", title: "Extract text", symbol: "text.viewfinder", group: .intelligence), at: 0) }
            m.translate = toLanguages.map { FileAction(id: "translate:\($0.id)", title: $0.name, symbol: "globe", group: .intelligence) }
        case .other:
            break
        }
        return m
    }

    /// Runs an action. Results are saved next to the original; the original is never touched.
    static func run(_ id: String, on url: URL, progress: @escaping ProgressSink) async throws -> ActionResult {
        let parts = id.components(separatedBy: ":")
        let option = parts.count > 1 ? parts[1] : nil
        switch parts[0] {
        case "removeBackground": return try await Images.removeBackground(url, progress)
        case "extractText": return try await Images.extractText(url, progress)
        case "image": return try await Images.convert(url, to: option ?? "png", progress)
        case "audio": return try await Audio.convert(url, to: option ?? "m4a", progress)
        case "transcribe": return try await Speech.transcribe(url, language: option ?? defaultSpeechLanguage, translateTo: nil, progress)
        case "transcribeTranslate": return try await Speech.transcribe(url, language: defaultSpeechLanguage, translateTo: option, progress)
        case "translate": return try await Texts.translate(url, to: option ?? "en", progress)
        case "summarize": return try await Texts.summarize(url, progress)
        default: throw ActionError(message: "Unknown action.")
        }
    }

    /// The language of this Mac, as a speech locale ("en-US").
    static var defaultSpeechLanguage: String {
        let id = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return speechLanguages.first { $0.code == id }?.code ?? speechLanguages.first { $0.code.hasPrefix(lang + "-") }?.code ?? "en-US"
    }

    /// "photo (no background).png", then "photo (no background) 2.png" if that exists.
    static func outputURL(next url: URL, suffix: String, ext: String) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

// MARK: - Pictures

enum Images {
    static func loadCGImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ActionError(message: "This picture can't be read.") }
        // Honour the camera's rotation so the result is the right way up.
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let o = props[kCGImagePropertyOrientation] as? UInt32, o != 1,
           let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(o)) as CIImage?,
           let cg = CIContext().createCGImage(oriented, from: oriented.extent) { return cg }
        return image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ActionError(message: "Couldn't create the picture.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ActionError(message: "Couldn't save the picture.") }
    }

    static func removeBackground(_ url: URL, _ progress: ProgressSink) async throws -> ActionResult {
        progress(ActionProgress(fraction: 0.1, status: "Finding the subject…"))
        let out = FileActions.outputURL(next: url, suffix: " (no background)", ext: "png")
        try await Task.detached(priority: .userInitiated) {
            let cg = try loadCGImage(url)
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw ActionError(message: "No clear subject was found in this picture.")
            }
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let result = CIContext().createCGImage(ci, from: ci.extent) else { throw ActionError(message: "Couldn't build the result.") }
            try writePNG(result, to: out)
        }.value
        progress(ActionProgress(fraction: 1, status: "Done"))
        return ActionResult(title: "Background removed", files: [out], text: nil)
    }

    static func recognize(_ cg: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let lines = (request.results ?? []).sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func extractText(_ url: URL, _ progress: ProgressSink) async throws -> ActionResult {
        let text: String
        if FileKind.of(url) == .pdf {
            text = try await Texts.pdfText(url, progress)
        } else {
            progress(ActionProgress(fraction: 0.2, status: "Reading the text…"))
            text = try await Task.detached(priority: .userInitiated) { try recognize(try loadCGImage(url)) }.value
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActionError(message: "No text was found.") }
        let out = FileActions.outputURL(next: url, suffix: " text", ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return ActionResult(title: "Text extracted", files: [out], text: text)
    }

    static func convert(_ url: URL, to format: String, _ progress: ProgressSink) async throws -> ActionResult {
        progress(ActionProgress(fraction: 0.2, status: "Converting…"))
        let small = format == "small"
        let type: UTType = small ? .jpeg : (format == "jpeg" ? .jpeg : format == "heic" ? .heic : .png)
        let ext = small ? "jpg" : (format == "jpeg" ? "jpg" : format)
        let out = FileActions.outputURL(next: url, suffix: small ? " (small)" : (url.pathExtension.lowercased() == ext ? " (converted)" : ""), ext: ext)
        try await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ActionError(message: "This picture can't be read.") }
            let image: CGImage
            if small {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 2048]
                guard let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw ActionError(message: "Couldn't shrink the picture.") }
                image = t
            } else {
                image = try loadCGImage(url)
            }
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
                throw ActionError(message: "This format can't be written on this Mac.")
            }
            let quality: Double = small ? 0.7 : 0.92
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ActionError(message: "Couldn't save the picture.") }
        }.value
        progress(ActionProgress(fraction: 1, status: "Done"))
        return ActionResult(title: small ? "Made smaller" : "Converted", files: [out], text: nil)
    }
}

// MARK: - Audio and video

enum Audio {
    static func convert(_ url: URL, to format: String, _ progress: @escaping ProgressSink) async throws -> ActionResult {
        if format == "wav" {
            let out = FileActions.outputURL(next: url, suffix: url.pathExtension.lowercased() == "wav" ? " (converted)" : "", ext: "wav")
            try await toWAV(url, out, progress)
            return ActionResult(title: "Converted to WAV", files: [out], text: nil)
        }
        let isVideo = FileKind.of(url) == .video
        let out = FileActions.outputURL(next: url, suffix: url.pathExtension.lowercased() == "m4a" ? " (converted)" : "", ext: "m4a")
        progress(ActionProgress(fraction: 0.02, status: isVideo ? "Extracting the audio…" : "Converting…"))
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ActionError(message: "This file's audio can't be converted.")
        }
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(ActionProgress(fraction: p.fractionCompleted, status: isVideo ? "Extracting the audio…" : "Converting…")) }
            }
        }
        defer { watcher.cancel() }
        do { try await session.export(to: out, as: .m4a) }
        catch { throw ActionError(message: "Couldn't convert this file: \(error.localizedDescription)") }
        progress(ActionProgress(fraction: 1, status: "Done"))
        return ActionResult(title: isVideo ? "Audio extracted" : "Converted to M4A", files: [out], text: nil)
    }

    /// WAV through PCM, any length (the sound is read and written in small pieces).
    static func toWAV(_ url: URL, _ out: URL, _ progress: @escaping ProgressSink) async throws {
        progress(ActionProgress(fraction: 0.02, status: "Reading the audio…"))
        let source: URL
        var temp: URL?
        if FileKind.of(url) == .video || (try? AVAudioFile(forReading: url)) == nil {
            let caf = try await AudioExtractor.extract(from: url)
            temp = caf
            source = caf
        } else {
            source = url
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        try await Task.detached(priority: .userInitiated) {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                           AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let output = try AVAudioFile(forWriting: out, settings: settings)
            let chunk: AVAudioFrameCount = 65536
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw ActionError(message: "Out of memory.") }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                progress(ActionProgress(fraction: 0.05 + 0.95 * Double(input.framePosition) / Double(max(input.length, 1)), status: "Converting…"))
            }
        }.value
    }
}

enum Speech {
    /// Transcribes with the proven speech engine, then saves the text and subtitles (and a translation if asked).
    static func transcribe(_ url: URL, language: String, translateTo target: String?, _ progress: @escaping ProgressSink) async throws -> ActionResult {
        let spokenShort = language.components(separatedBy: "-").first ?? language
        let result = try await SpeechEngine.transcribe(url: url, languageCode: language, vocabulary: [], resume: true) { u in
            let part = (target == nil) ? 1.0 : 0.85
            progress(ActionProgress(fraction: u.fraction.map { $0 * part }, status: u.snippet.map { "“" + $0.suffix(60) + "”" } ?? u.status ?? "Listening…"))
        }
        let cues = CueSegmenter.cues(from: result.words, style: .standard)
        guard !cues.isEmpty else { throw ActionError(message: "No speech was found in this file.") }
        let transcript = paragraphs(from: cues)
        var files: [URL] = []

        let txt = FileActions.outputURL(next: url, suffix: " transcript", ext: "txt")
        try transcript.write(to: txt, atomically: true, encoding: .utf8)
        let srt = FileActions.outputURL(next: url, suffix: "", ext: "srt")
        try SubtitleFiles.text(cues, format: .srt).write(to: srt, atomically: true, encoding: .utf8)
        files = [txt, srt]
        var shown = transcript
        var title = "Transcribed"

        if let target, target != spokenShort {
            progress(ActionProgress(fraction: 0.86, status: "Translating to \(Translator.name(target))…"))
            let translated = try await Translator.translate(cues.map(\.text), from: spokenShort, to: target) { f in
                progress(ActionProgress(fraction: 0.86 + 0.13 * f, status: "Translating to \(Translator.name(target))…"))
            }
            let tcues = zip(cues, translated).map { SubtitleCue(text: $1, start: $0.start, end: $0.end) }
            let ttxt = FileActions.outputURL(next: url, suffix: " transcript (\(Translator.name(target)))", ext: "txt")
            try paragraphs(from: tcues).write(to: ttxt, atomically: true, encoding: .utf8)
            let tsrt = FileActions.outputURL(next: url, suffix: " (\(Translator.name(target)))", ext: "srt")
            try SubtitleFiles.text(tcues, format: .srt).write(to: tsrt, atomically: true, encoding: .utf8)
            files += [ttxt, tsrt]
            shown = paragraphs(from: tcues)
            title = "Transcribed and translated"
        }
        if let warning = result.warning { shown += "\n\n(" + warning + ")" }
        progress(ActionProgress(fraction: 1, status: "Done"))
        return ActionResult(title: title, files: files, text: shown)
    }

    /// Just the words, for answering questions: no files are written next to the original.
    static func transcriptText(_ url: URL, language: String, _ progress: @escaping ProgressSink) async throws -> String {
        let result = try await SpeechEngine.transcribe(url: url, languageCode: language, vocabulary: [], resume: true) { u in
            progress(ActionProgress(fraction: u.fraction, status: u.status ?? "Listening…"))
        }
        let cues = CueSegmenter.cues(from: result.words, style: .standard)
        guard !cues.isEmpty else { throw ActionError(message: "No speech was found in this file.") }
        return paragraphs(from: cues)
    }

    /// Lines of text, with a blank line wherever the speaker paused for a while.
    static func paragraphs(from cues: [SubtitleCue]) -> String {
        var out = ""
        for (i, c) in cues.enumerated() {
            if i > 0 { out += (c.start - cues[i - 1].end > 1.8) ? "\n\n" : " " }
            out += c.text.replacingOccurrences(of: "\n", with: " ")
        }
        return out
    }
}

// MARK: - Text and PDF

// MARK: - Zip

enum Archive {
    /// Puts several files (or folders) in one zip next to the first. The originals are not touched.
    static func zip(_ urls: [URL], _ progress: ProgressSink) async throws -> ActionResult {
        guard let first = urls.first else { throw ActionError(message: "There is nothing to zip.") }
        progress(ActionProgress(fraction: 0.1, status: "Gathering the files…"))
        let out = FileActions.outputURL(next: first, suffix: urls.count > 1 ? " and \(urls.count - 1) more" : "", ext: "zip")
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stage = fm.temporaryDirectory.appendingPathComponent("notchplus-zip-\(UUID().uuidString)")
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }
            // links to the files under unique names, so two files called the same do not collide
            var names: [String] = []
            for u in urls {
                var name = u.lastPathComponent
                var n = 2
                while names.contains(name) {
                    let base = u.deletingPathExtension().lastPathComponent
                    name = u.pathExtension.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(u.pathExtension)"
                    n += 1
                }
                names.append(name)
                try fm.createSymbolicLink(at: stage.appendingPathComponent(name), withDestinationURL: u)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = stage
            p.arguments = ["-qr", out.path] + names           // without -y, links are stored as the files they point to
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                try? fm.removeItem(at: out)
                throw ActionError(message: "The zip could not be made.")
            }
        }.value
        progress(ActionProgress(fraction: 1, status: "Done"))
        return ActionResult(title: "Zipped \(urls.count) files", files: [out], text: nil)
    }
}

enum Texts {
    /// The words of a PDF; pages without text are read with text recognition.
    static func pdfText(_ url: URL, _ progress: ProgressSink) async throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ActionError(message: "This PDF can't be opened.") }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            progress(ActionProgress(fraction: Double(i) / Double(max(doc.pageCount, 1)), status: "Page \(i + 1) of \(doc.pageCount)…"))
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 20 {                                   // a scan: read the picture of the page
                let box = page.bounds(for: .mediaBox)
                let scale = 2.0
                let img = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
                if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    text = (try? await Task.detached { try Images.recognize(cg) }.value) ?? text
                }
            }
            if !text.isEmpty { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
    }

    /// The text of a text, PDF or subtitle file.
    static func read(_ url: URL, _ progress: ProgressSink) async throws -> String {
        if FileKind.of(url) == .pdf { return try await pdfText(url, progress) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .utf16) else {
            throw ActionError(message: "This file can't be read as text.")
        }
        return text
    }

    static func translate(_ url: URL, to target: String, _ progress: @escaping ProgressSink) async throws -> ActionResult {
        progress(ActionProgress(fraction: 0.05, status: "Reading…"))
        let text = try await read(url, progress)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActionError(message: "There is no text to translate.") }
        let source = Translator.detect(text) ?? "en"
        if source == target { throw ActionError(message: "This text is already in \(Translator.name(target)).") }
        // translate line by line so the layout survives
        let lines = text.components(separatedBy: "\n")
        let indexes = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let translated = try await Translator.translate(indexes.map { lines[$0] }, from: source, to: target) { f in
            progress(ActionProgress(fraction: 0.1 + 0.88 * f, status: "Translating to \(Translator.name(target))…"))
        }
        var out = lines
        for (k, i) in indexes.enumerated() { out[i] = translated[k] }
        let result = out.joined(separator: "\n")
        let file = FileActions.outputURL(next: url, suffix: " (\(Translator.name(target)))", ext: "txt")
        try result.write(to: file, atomically: true, encoding: .utf8)
        return ActionResult(title: "Translated to \(Translator.name(target))", files: [file], text: result)
    }

    static func summarize(_ url: URL, _ progress: @escaping ProgressSink) async throws -> ActionResult {
        var text: String
        var files: [URL] = []
        switch FileKind.of(url) {
        case .audio, .video:
            let transcribed = try await Speech.transcribe(url, language: FileActions.defaultSpeechLanguage, translateTo: nil) { p in
                progress(ActionProgress(fraction: (p.fraction ?? 0) * 0.7, status: p.status))
            }
            text = transcribed.text ?? ""
            files = transcribed.files
        default:
            progress(ActionProgress(fraction: 0.05, status: "Reading…"))
            text = try await read(url, progress)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActionError(message: "There is nothing to summarize.") }
        let base = (FileKind.of(url) == .audio || FileKind.of(url) == .video) ? 0.7 : 0.1
        guard let summary = await Intelligence.summarize(text, progress: { f in
            progress(ActionProgress(fraction: base + (1 - base) * f, status: "Summarizing…"))
        }) else {
            throw ActionError(message: "Apple Intelligence isn't available on this Mac right now, so it can't write a summary.")
        }
        let file = FileActions.outputURL(next: url, suffix: " summary", ext: "txt")
        try summary.write(to: file, atomically: true, encoding: .utf8)
        return ActionResult(title: "Summary ready", files: [file] + files, text: summary)
    }
}
