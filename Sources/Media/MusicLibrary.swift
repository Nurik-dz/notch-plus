import Foundation

/// One line of a song's words. `time` is when it is sung (seconds) when the lyrics are synced, otherwise nil.
struct LyricLine: Equatable {
    let time: Double?
    let text: String
}

/// Reads lyrics the way files store them: "[01:02.50] words", often several stamps in a row. Plain text works too.
enum LyricsParser {
    static func parse(_ raw: String) -> [LyricLine] {
        let text = raw.replacingOccurrences(of: "\r", with: "\n")
        guard let tag = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#) else { return [] }
        let ns = text as NSString
        let found = tag.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if found.isEmpty {
            return text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { LyricLine(time: nil, text: $0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.text.isEmpty }
        }
        var lines: [LyricLine] = []
        for (i, m) in found.enumerated() {
            let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
            let start = m.range.location + m.range.length
            let end = i + 1 < found.count ? found[i + 1].range.location : ns.length
            let words = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { lines.append(LyricLine(time: minutes * 60 + seconds, text: words)) }
        }
        return lines.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }

    /// The line being sung at `now`: the last one whose time has come. Nil before the first line or for plain lyrics.
    static func current(in lines: [LyricLine], at now: Double) -> Int? {
        guard lines.contains(where: { $0.time != nil }) else { return nil }
        return lines.lastIndex { ($0.time ?? .infinity) <= now }
    }
}

/// A song on the album or playlist that is playing.
struct AlbumTrack: Equatable, Identifiable {
    let id: String          // Music's persistent id
    let name: String
    let duration: Double
    var artist = ""
    var album = ""
}

/// What Music can tell about the song that plays: the words and the list it plays from. Only songs that are files
/// in the library have these; streamed songs give nothing, and then the player simply shows no buttons for them.
struct MusicTrackInfo: Equatable {
    let key: String
    var lyrics: [LyricLine]
    var tracks: [AlbumTrack]
    var currentID: String
}

/// The few switches Music has for what plays: the favourite star, shuffle and repeat.
struct MusicControls: Equatable {
    enum Repeat: String { case off, all, one
        var next: Repeat { switch self { case .off: .all; case .all: .one; case .one: .off } }
    }
    var favorited: Bool
    var shuffle: Bool
    var repeatMode: Repeat

    /// Reads Music's answer "true|false|off" (favourite, shuffle, repeat).
    static func parse(_ answer: String) -> MusicControls? {
        let f = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard f.count == 3, let r = Repeat(rawValue: f[2]) else { return nil }
        return MusicControls(favorited: f[0] == "true", shuffle: f[1] == "true", repeatMode: r)
    }
}

enum MusicLibrary {
    static let bundleID = "com.apple.Music"
    /// A whole library is not a list worth showing.
    static let longestList = 200

    /// Splits the track script's answer: the playing song's id on the first line, then "id, name, seconds, artist, album" per track.
    static func parseTracks(_ answer: String) -> (currentID: String, tracks: [AlbumTrack]) {
        let rows = answer.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard let first = rows.first, rows.count > 1 else { return ("", []) }
        let tracks = rows.dropFirst().compactMap { row -> AlbumTrack? in
            let f = row.components(separatedBy: "\t")
            guard f.count >= 3, !f[0].isEmpty else { return nil }
            return AlbumTrack(id: f[0], name: f[1], duration: Double(f[2].replacingOccurrences(of: ",", with: ".")) ?? 0,
                              artist: f.count > 3 ? f[3] : "", album: f.count > 4 ? f[4] : "")
        }
        return (first.trimmingCharacters(in: .whitespaces), tracks)
    }

    private static let queue = DispatchQueue(label: "notchplus.music-library")

    private static func run(_ source: String) async -> String? {
        await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                cont.resume(returning: error == nil ? result?.stringValue : nil)
            }
        }
    }

    /// Asks Music (the first time, macOS asks you to allow it). Nil when Music is not playing a library song.
    static func fetch(key: String) async -> MusicTrackInfo? {
        let lyricsScript = """
        tell application "Music"
            if player state is stopped then return ""
            try
                return lyrics of current track
            on error
                return ""
            end try
        end tell
        """
        let tracksScript = """
        tell application "Music"
            if player state is stopped then return ""
            try
                set t to current track
                set p to current playlist
                if (count of tracks of p) > \(longestList) then return ""
                set ids to persistent ID of every track of p
                set ns to name of every track of p
                set ds to duration of every track of p
                set ars to artist of every track of p
                set als to album of every track of p
                set out to persistent ID of t
                repeat with i from 1 to count of ids
                    set out to out & linefeed & (item i of ids) & tab & (item i of ns) & tab & (item i of ds) & tab & (item i of ars) & tab & (item i of als)
                end repeat
                return out
            on error
                return ""
            end try
        end tell
        """
        async let l = run(lyricsScript)
        async let t = run(tracksScript)
        let (rawLyrics, rawTracks) = await (l, t)
        let lyrics = LyricsParser.parse(rawLyrics ?? "")
        let parsed = parseTracks(rawTracks ?? "")
        let tracks = parsed.tracks.count > 1 ? parsed.tracks : []       // one song is not a list
        if lyrics.isEmpty && tracks.isEmpty { return nil }
        return MusicTrackInfo(key: key, lyrics: lyrics, tracks: tracks, currentID: parsed.currentID)
    }

    /// The star, shuffle and repeat as they are now. Nil when Music does not answer.
    static func controls() async -> MusicControls? {
        let source = """
        tell application "Music"
            if player state is stopped then return ""
            try
                return ((favorited of current track) as string) & "|" & (shuffle enabled as string) & "|" & (song repeat as string)
            on error
                return ""
            end try
        end tell
        """
        guard let answer = await run(source) else { return nil }
        return MusicControls.parse(answer)
    }

    static func setFavorite(_ on: Bool) { Task.detached { _ = await run("tell application \"Music\" to set favorited of current track to \(on)") } }
    static func setShuffle(_ on: Bool) { Task.detached { _ = await run("tell application \"Music\" to set shuffle enabled to \(on)") } }
    static func setRepeat(_ mode: MusicControls.Repeat) { Task.detached { _ = await run("tell application \"Music\" to set song repeat to \(mode.rawValue)") } }

    /// Nothing is playing: opens Music in the background and plays where you left off; if Music has nothing queued,
    /// it shuffles your whole library.
    static func startPlaying() {
        let source = """
        tell application "Music"
            launch
            try
                play
            end try
            delay 1.5
            if player state is stopped then
                set shuffle enabled to true
                play library playlist 1
            end if
        end tell
        """
        Task.detached { _ = await run(source) }
    }

    /// How far (in songs) a click on the list may travel before Notch+ plays the song directly instead.
    static let longestStep = 60

    /// Plays a song from the list that is playing. Music's own "play this track" makes a one-song queue (then "next"
    /// just repeats it), so instead Notch+ steps through the queue that is already there, paused and quietly, by the
    /// number of songs between the playing one and the one you clicked, and plays. The rest of the album carries on.
    /// Shuffle, a song that is not in this list, or a very long way fall back to playing the song directly.
    static func play(id: String) {
        let safe = id.filter { $0.isLetter || $0.isNumber }
        guard !safe.isEmpty else { return }
        let source = """
        tell application "Music"
            set p to current playlist
            set t to first track of p whose persistent ID is "\(safe)"
            set direct to shuffle enabled
            set d to 0
            try
                set d to (index of t) - (index of current track)
            on error
                set direct to true
            end try
            if direct or d > \(longestStep) or d < -\(longestStep) then
                play t
                return
            end if
            if d is 0 then
                set player position to 0
                play
                return
            end if
            pause
            if d > 0 then
                repeat d times
                    next track
                    delay 0.12
                end repeat
            else
                repeat (0 - d) times
                    set player position to 0
                    previous track
                    delay 0.12
                end repeat
            end if
            play
        end tell
        """
        Task.detached { _ = await run(source) }
    }
}
