import Foundation

enum SegmentationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case compact
    case shortForm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .compact: return "Single Line"
        case .shortForm: return "Short-form"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "Up to two balanced lines, broken at sentences and pauses. Best for films, talks and audiobooks."
        case .compact: return "One short line at a time. Easier to follow on small screens."
        case .shortForm: return "A few punchy words at a time, for Shorts, Reels and TikTok."
        }
    }

    fileprivate var maxCharacters: Int {
        switch self {
        case .standard: return 84
        case .compact: return 42
        case .shortForm: return 22
        }
    }

    fileprivate var maxDuration: Double {
        switch self {
        case .standard: return 6
        case .compact: return 4
        case .shortForm: return 2
        }
    }

    fileprivate var pauseBreak: Double {
        switch self {
        case .standard: return 0.6
        case .compact: return 0.5
        case .shortForm: return 0.35
        }
    }

    fileprivate var minDuration: Double {
        self == .shortForm ? 0.4 : 0.8
    }
}

/// Groups timed words into subtitle lines.
enum CueSegmenter {
    private static let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]
    private static let clauseEnders: Set<Character> = [",", ";", ":", "，", "、", "；"]

    /// - Parameter breaks: word positions where a new line must start (the
    ///   start and end of a song, and each line of a song).
    static func cues(from words: [TranscribedWord], style: SegmentationStyle, breaks: Set<Int> = []) -> [SubtitleCue] {
        guard !words.isEmpty else { return [] }

        var cues: [SubtitleCue] = []
        var bucket: [TranscribedWord] = []
        var bucketChars = 0

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            var text = bucket.map(\.text).joined()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if style == .standard { text = balance(text) }
            let confidences = bucket.compactMap(\.confidence)
            let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
            bucket.removeAll()
            bucketChars = 0
            guard !text.isEmpty else { return }
            cues.append(SubtitleCue(text: text, start: first.start, end: last.end, confidence: confidence))
        }

        for (position, word) in words.enumerated() {
            if !bucket.isEmpty, breaks.contains(position) {
                flush()
            }
            if let last = bucket.last, let first = bucket.first {
                let gap = word.start - last.end
                let chars = bucketChars + word.text.count
                let tail = last.text.trimmingCharacters(in: .whitespaces).last
                let endsSentence = tail.map { sentenceEnders.contains($0) } ?? false
                let endsClause = tail.map { clauseEnders.contains($0) } ?? false
                let filled = Double(bucketChars) / Double(style.maxCharacters)

                if gap > style.pauseBreak
                    || word.end - first.start > style.maxDuration
                    || chars > style.maxCharacters
                    || (endsSentence && filled >= 0.35)
                    || (endsClause && filled >= 0.7) {
                    flush()
                }
            }
            bucket.append(word)
            bucketChars += word.text.count
        }
        flush()

        // Let each line linger slightly past its last word, which is easier to
        // read, but never into the next line, and never shorter than a flash.
        for i in cues.indices {
            let nextStart = i + 1 < cues.count ? cues[i + 1].start : Double.greatestFiniteMagnitude
            var end = max(cues[i].end + 0.25, cues[i].start + style.minDuration)
            end = min(end, nextStart - 0.04)
            cues[i].end = max(end, cues[i].start + 0.2)
        }
        return cues
    }

    /// Splits a long line into two lines of similar width at the space
    /// nearest the middle, the way broadcast subtitles are laid out.
    static func balance(_ text: String, threshold: Int = 42) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > threshold, flat.contains(" ") else { return flat }
        let middle = flat.count / 2
        var best: String.Index?
        var bestDistance = Int.max
        var offset = 0
        for index in flat.indices {
            if flat[index] == " " {
                let distance = abs(offset - middle)
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            offset += 1
        }
        guard let best else { return flat }
        return String(flat[..<best]) + "\n" + String(flat[flat.index(after: best)...])
    }
}
