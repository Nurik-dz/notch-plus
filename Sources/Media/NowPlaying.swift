import AppKit

/// What is playing on this Mac right now (any app, including web video in a browser).
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    /// The app to open when you click the card (the browser, for web video).
    var bundleID: String
    var playing: Bool
    var duration: Double
    var elapsed: Double
    var rate: Double
    var stamp: Date
    var artwork: NSImage?
    var artworkKey: Int

    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album && a.bundleID == b.bundleID && a.playing == b.playing
            && a.duration == b.duration && a.elapsed == b.elapsed && a.rate == b.rate && a.stamp == b.stamp && a.artworkKey == b.artworkKey
    }

    /// Position now, estimated from the last report while it plays.
    func elapsedNow(_ now: Date = Date()) -> Double {
        guard playing else { return elapsed }
        let t = elapsed + now.timeIntervalSince(stamp) * max(rate, 1)
        return duration > 0 ? min(t, duration) : t
    }

    /// Something worth a card: it has a title.
    var isMeaningful: Bool { !title.isEmpty }
}

enum MediaCommand: Int {
    case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5
}

enum NowPlayingParser {
    enum Result: Equatable {
        case info(NowPlayingInfo)
        case cleared        // nothing is playing
        case invalid
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// One JSON line from the adapter: either {"type":"data","payload":{...}} or the payload itself.
    static func parse(line: Data) -> Result {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return .invalid }
        let p = (obj["payload"] as? [String: Any]) ?? obj
        if p.isEmpty { return .cleared }
        let title = (p["title"] as? String) ?? ""
        guard !title.isEmpty else { return .cleared }

        let bundle = (p["parentApplicationBundleIdentifier"] as? String)
            ?? (p["bundleIdentifier"] as? String) ?? ""
        let rate = (p["playbackRate"] as? Double) ?? 0
        let playing = (p["playing"] as? Bool) ?? (rate > 0)
        let stamp = (p["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()

        var image: NSImage?
        var key = 0
        if let b64 = p["artworkData"] as? String, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !data.isEmpty {
            image = NSImage(data: data)
            key = data.count &* 31 &+ Int(data.first ?? 0)
        }
        return .info(NowPlayingInfo(
            title: title, artist: (p["artist"] as? String) ?? "", album: (p["album"] as? String) ?? "",
            bundleID: bundle, playing: playing,
            duration: (p["duration"] as? Double) ?? 0, elapsed: (p["elapsedTime"] as? Double) ?? 0,
            rate: rate, stamp: stamp, artwork: image, artworkKey: key))
    }
}

/// Runs Apple's trusted perl with the bundled adapter to read and control "now playing".
/// (macOS only lets a few system tools talk to the media service directly.)
@MainActor
final class NowPlayingController {
    private let script: URL?
    private let framework: URL?
    private var process: Process?
    private var buffer = Data()
    private var stopped = true
    var onChange: ((NowPlayingInfo?) -> Void)?

    init(script: URL?, framework: URL?) {
        self.script = script
        self.framework = framework
    }

    /// The adapter inside the app bundle.
    static func bundled() -> NowPlayingController {
        NowPlayingController(
            script: Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            framework: Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"))
    }

    var isAvailable: Bool {
        guard let script, let framework else { return false }
        return FileManager.default.fileExists(atPath: script.path) && FileManager.default.fileExists(atPath: framework.path)
    }

    @discardableResult
    func start() -> Bool {
        guard isAvailable, let script, let framework else { return false }
        stopped = false
        launch(script: script, framework: framework)
        return true
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launch(script: URL, framework: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path, "stream", "--no-diff"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                try? await Task.sleep(for: .seconds(3))
                if !self.stopped, let s = self.script, let f = self.framework { self.launch(script: s, framework: f) }
            }
        }
        do { try p.run(); process = p } catch { process = nil }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<nl])
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard !line.isEmpty else { continue }
            switch NowPlayingParser.parse(line: line) {
            case .info(let i): onChange?(i)
            case .cleared: onChange?(nil)
            case .invalid: break
            }
        }
    }

    // MARK: - Control

    func send(_ command: MediaCommand) { run(["send", String(command.rawValue)]) }

    /// The adapter's own "seek" is refused by macOS 27 (checked with Brave), so a small helper sends the
    /// system's "change playback position" command instead (Vendor/npseek.m, run by the same trusted perl).
    func seek(to seconds: Double) {
        guard let dir = script?.deletingLastPathComponent() else { return }
        let helper = dir.appendingPathComponent("npseek.pl"), lib = dir.appendingPathComponent("libnpseek.dylib")
        guard FileManager.default.fileExists(atPath: lib.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [helper.path, lib.path, "np_seek_command", String(max(0, seconds))]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func run(_ args: [String]) {
        guard isAvailable, let script, let framework else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
