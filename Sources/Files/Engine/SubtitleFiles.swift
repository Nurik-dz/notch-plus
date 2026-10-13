import Foundation

/// One subtitle line.
struct SubtitleCue: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double? = nil
}

/// Subtitle files (.srt, .vtt) from the transcript's timed words.
enum SubtitleFiles {
    enum Format: String, CaseIterable, Identifiable {
        case srt, vtt
        var id: String { rawValue }
    }

    static func text(_ cues: [SubtitleCue], format: Format) -> String {
        var out = format == .vtt ? "WEBVTT\n\n" : ""
        for (i, cue) in cues.enumerated() {
            if format == .srt { out += "\(i + 1)\n" }
            out += "\(stamp(cue.start, format)) --> \(stamp(cue.end, format))\n\(cue.text)\n\n"
        }
        return out
    }

    /// "01:02:03,450" (SRT) or "01:02:03.450" (VTT).
    static func stamp(_ seconds: Double, _ format: Format) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, format == .srt ? "," : ".", ms % 1000)
    }
}
