import Foundation
import AVFoundation

struct MediaInfo: Sendable {
    var duration: Double
    var hasVideo: Bool
    /// Display-oriented frame size (rotation applied). 1920x1080 for audio.
    var canvasSize: CGSize

    static func load(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let seconds = try await mediaLength(of: asset)
        guard seconds.isFinite, seconds > 0 else {
            throw FFmpeg.Failure(message: "Couldn't read the length of this file. It may be damaged or in an unsupported format.")
        }
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let shown = size.applying(transform)
            let canvas = CGSize(width: abs(shown.width), height: abs(shown.height))
            if canvas.width > 1, canvas.height > 1 {
                return MediaInfo(duration: seconds, hasVideo: true, canvasSize: canvas)
            }
        }
        return MediaInfo(duration: seconds, hasVideo: false, canvasSize: CGSize(width: 1920, height: 1080))
    }
}

/// The length of the actual sound and picture. The container's own duration
/// can be longer: a text or data track in an edited file may still claim the
/// length of the original recording.
func mediaLength(of asset: AVURLAsset) async throws -> Double {
    var longest = 0.0
    for track in try await asset.load(.tracks) where track.mediaType == .audio || track.mediaType == .video {
        let range = try await track.load(.timeRange)
        longest = max(longest, range.end.seconds)
    }
    if longest > 0, longest.isFinite { return longest }
    return try await asset.load(.duration).seconds
}

enum AudioExtractor {
    /// Extracts a time-bounded slice of the audio track as lossless PCM in a
    /// CAF container.
    ///
    /// CAF rather than WAV: WAV stores sizes in 32 bits and silently truncates
    /// past 4 GiB (about 6h45m of 44.1kHz stereo), which is how whole-file WAV
    /// extraction loses the back half of very long recordings. Audio is not
    /// downsampled: the speech engine resamples internally, and doing it
    /// earlier only throws away signal that helps on quiet lines.
    static func extract(from url: URL, start: Double = 0, duration: Double? = nil) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory
        let caf = temp.appendingPathComponent("subtitle-studio-\(UUID().uuidString.prefix(8)).caf")

        if FFmpeg.locate() != nil {
            // Two-stage seek: the input -ss jumps quickly through the index to
            // a little before the target, then the output -ss decodes the rest
            // sample-exactly. A fast seek alone can land up to a second late
            // on AAC, which shifts every timestamp in the window.
            let lead = min(start, 10.0)
            let roughStart = start - lead
            var arguments: [String] = []
            if roughStart > 0 { arguments += ["-ss", String(format: "%.6f", roughStart)] }
            arguments += ["-i", url.path]
            if lead > 0 { arguments += ["-ss", String(format: "%.6f", lead)] }
            if let duration { arguments += ["-t", String(format: "%.6f", duration)] }
            arguments += ["-vn", "-sn", "-dn", "-c:a", "pcm_s16le", "-f", "caf", caf.path]
            do {
                try await FFmpeg.run(arguments)
                if FileManager.default.fileExists(atPath: caf.path) { return caf }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: caf)
                throw CancellationError()
            } catch {
                // Fall through to AVFoundation.
            }
            try? FileManager.default.removeItem(at: caf)
        }

        let m4a = temp.appendingPathComponent("subtitle-studio-\(UUID().uuidString.prefix(8)).m4a")
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw FFmpeg.Failure(message: "This file's audio can't be read.")
        }
        if start > 0 || duration != nil {
            let startTime = CMTime(seconds: start, preferredTimescale: 44_100)
            let length = duration.map { CMTime(seconds: $0, preferredTimescale: 44_100) } ?? .positiveInfinity
            session.timeRange = CMTimeRange(start: startTime, duration: length)
        }
        try await session.export(to: m4a, as: .m4a)
        return m4a
    }
}
