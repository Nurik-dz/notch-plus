import Foundation
import SwiftUI

struct ApprovalRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let tool: String
    let headline: String
    let detail: String
    let cwd: String
    let branch: String?
    let risk: Risk
    let suggestions: [[String: Any]]
    /// The tool's input as Claude sent it (echoed back when answering Claude's questions).
    var input: [String: Any] = [:]
    let receivedAt = Date()

    /// Claude asking you something (its AskUserQuestion tool) instead of asking to run something.
    var questions: [ClaudeQuestion] { tool == "AskUserQuestion" ? ClaudeQuestion.parse(input) : [] }
    var isQuestion: Bool { !questions.isEmpty }

    var folderName: String { cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent }
    /// "Allow Always" only when Claude suggested a rule and the request is not risky.
    var canAllowAlways: Bool { !suggestions.isEmpty && risk < .high }
    /// A small icon that says what kind of thing this is.
    var symbol: String {
        switch tool {
        case "Bash": "terminal"
        case "Read", "Glob", "Grep", "LS": "doc.text.magnifyingglass"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil.line"
        case "Write": "square.and.pencil"
        case "WebFetch", "WebSearch": "globe"
        default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "gearshape"
        }
    }
}

enum Outcome {
    case allowed, allowedAlways, denied, answeredElsewhere
    /// Short enough to sit beside the notch.
    var short: String {
        switch self {
        case .allowed: "Allowed"
        case .allowedAlways: "Always"
        case .denied: "Denied"
        case .answeredElsewhere: "Terminal"
        }
    }
    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .allowedAlways: "Always allowed"
        case .denied: "Denied"
        case .answeredElsewhere: "Answered in the terminal"
        }
    }
}

struct HistoryEntry: Identifiable {
    let id = UUID()
    let headline: String
    let detail: String
    let outcome: Outcome
    let date = Date()
}

@MainActor
final class NotchModel: ObservableObject {
    struct Pending {
        let request: ApprovalRequest
        let connection: HookConnection
    }

    /// A short moment shown beside the notch, such as "Allowed" after you answer.
    struct Flash: Equatable {
        let symbol: String
        let text: String
        let good: Bool
    }

    enum NotificationAccess: Equatable { case unknown, granted, needsFullDiskAccess }

    // Claude Code
    @Published var pending: [Pending] = []
    @Published var sessions: [String: ClaudeSession] = [:]
    @Published var finished: ClaudeFinish?
    @Published var finishedLog: [ClaudeFinish] = []
    @Published var history: [HistoryEntry] = []
    @Published var explanations: [UUID: String] = [:]
    @Published var explaining: Set<UUID> = []
    @Published var hookStatus: HookInstaller.Status = .notConnected

    // Notifications
    @Published var toast: CapturedNotification?
    @Published var notifications: [CapturedNotification] = []
    @Published var notificationAccess: NotificationAccess = .unknown

    // The island
    @Published var hovering = false
    @Published var flash: Flash?
    /// The volume or brightness you just changed, shown beside the notch.
    @Published var hud: HUDReading?
    @Published var serverProblem: String?
    @Published var tick = Date()      // moves every few seconds so live timers and stale sessions refresh
    /// The pointer is near the notch but has not stayed long enough to open it: the island leans in a little.
    @Published var anticipating = false
    /// Real heights of the open cards, measured by the views, so the island hugs its content.
    @Published var contentHeights: [IslandState: CGFloat] = [:]

    func report(height: CGFloat, for state: IslandState) {
        if abs((contentHeights[state] ?? 0) - height) > 0.5 { contentHeights[state] = height }
    }

    let rules: NotificationRules
    let defaults: UserDefaults
    /// Hooks for tests and for the real app.
    var triage: ((RawNotification) async -> TriageResult?)?
    var explain: ((ApprovalRequest) async -> String?)?
    var focusIsOn: () -> Bool = { false }

    /// The island glows brighter for a moment: Claude has waited long for an answer.
    @Published var pulsing = false
    private var lastPulse = Date.distantPast
    private var flashTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /// Notification cards waiting for the one on screen to close, with how long each stays.
    @Published private var toastQueue: [(note: CapturedNotification, seconds: Double)] = []
    private var finishedTask: Task<Void, Never>?
    private var clock: Timer?

    // Home: the player and the shelf
    enum HomeTab: Hashable { case player, shelf, recent }
    @Published var nowPlaying: NowPlayingInfo?
    @Published var homeChoice: HomeTab?           // what you picked yourself; nil = automatic
    @Published var dragging = false               // a file drag is near the notch
    @Published var dropTargeted = false
    let shelf: ShelfStore
    /// The basket's own files, used only when the basket is set not to send files to the shelf.
    let basketStore: ShelfStore
    /// Which files are selected (on the shelf or in the basket).
    @Published var selection = ShelfSelection()
    /// Sends play, pause, next... to whatever is playing. Set by the app; stubbed in tests.
    var mediaSend: ((MediaCommand) -> Void)?
    var mediaSeek: ((Double) -> Void)?

    init(rules: NotificationRules = NotificationRules(), defaults: UserDefaults = .standard,
         shelf: ShelfStore? = nil, basketStore: ShelfStore? = nil) {
        self.rules = rules
        self.defaults = defaults
        self.shelf = shelf ?? ShelfStore(file: AppPaths().shelfFile)
        self.basketStore = basketStore ?? ShelfStore(file: AppPaths().basketFile)
        caffeine.onExpire = { [weak self] in
            self?.showFlash(Flash(symbol: "moon.zzz.fill", text: "Can sleep", good: true), seconds: 2.2)
            self?.objectWillChange.send()
        }
    }

    /// The player when something is playing, otherwise the shelf, unless you chose a tab.
    var homeTab: HomeTab {
        if dragging || dropTargeted { return .shelf }
        if let c = homeChoice, c != .recent || !notifications.isEmpty { return c }
        return nowPlaying?.isMeaningful == true ? .player : .shelf     // paused is still the player, so play can be pressed again
    }

    var showMusicBesideNotch: Bool {
        get { defaults.object(forKey: "musicWings") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "musicWings"); objectWillChange.send() }
    }
    /// Music is playing and the user wants it beside the notch.
    var musicWingsOn: Bool { showMusicBesideNotch && nowPlaying?.isMeaningful == true && nowPlaying?.playing == true }

    /// Beside the notch: each wing only as wide as what it shows (Claude's tool and timer need the most).
    var wingsWidth: CGFloat {
        if hud != nil || flash != nil { return 90 }
        if liveSession != nil { return NotchGeometry.wingWidth }
        if !jobs.isEmpty { return 60 }
        if songPeek != nil, musicWingsOn { return 195 }
        return 50
    }

    /// Music keeps playing while something else is beside the notch: it moves into a small black drop
    /// that splits off the island's right end (like the iPhone's second Live Activity).
    var musicBubble: Bool {
        musicWingsOn && state == .wings && (hud != nil || flash != nil || liveSession != nil || !jobs.isEmpty)
    }

    /// The new song's title and artist, shown beside the notch for a moment after the song changes.
    struct SongPeek: Equatable { let title: String; let artist: String }
    @Published var songPeek: SongPeek?
    private var songPeekTask: Task<Void, Never>?

    var showSongPeek: Bool {
        get { defaults.object(forKey: "songPeek") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "songPeek"); if !newValue { songPeek = nil }; objectWillChange.send() }
    }
    /// A two-finger swipe left or right over the closed notch skips to the next or the previous song.
    var swipeSkips: Bool {
        get { defaults.object(forKey: "swipeSkips") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "swipeSkips"); objectWillChange.send() }
    }
    private var lastSwipeSkip = Date.distantPast
    func rewindSwipeClockForTests() { lastSwipeSkip = .distantPast }
    /// Swipe right for the next song, left for the previous one. It works on the closed notch and on the open player
    /// (pointing at the notch opens it within a third of a second, so that is where the swipe really happens);
    /// never on the shelf or on a card, where a sideways swipe means nothing.
    func skipBySwipe(next: Bool) {
        guard swipeSkips, nowPlaying?.isMeaningful == true, asking == nil, replying == nil else { return }
        let onPlayer = state == .overview && homeTab == .player
        guard !hovering || onPlayer else { return }
        guard Date().timeIntervalSince(lastSwipeSkip) > 0.5 else { return }      // one swipe, one song
        lastSwipeSkip = Date()
        sendMedia(next ? .next : .previous)
    }

    private func peekIfSongChanged(from old: NowPlayingInfo?, to new: NowPlayingInfo?) {
        guard showSongPeek, showMusicBesideNotch, let old, old.isMeaningful, let new, new.isMeaningful, new.playing,
              old.title != new.title || old.artist != new.artist else { return }
        songPeek = SongPeek(title: new.title, artist: new.artist)
        songPeekTask?.cancel()
        songPeekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.songPeek = nil
        }
    }

    func setNowPlaying(_ info: NowPlayingInfo?) {
        let wasPlaying = nowPlaying?.playing == true
        let wasThere = nowPlaying?.isMeaningful == true
        peekIfSongChanged(from: nowPlaying, to: info)
        nowPlaying = info
        // a fresh start, or the player going away, hands the home view back to automatic (pausing does not)
        if info?.playing == true, !wasPlaying { homeChoice = nil }
        if wasThere, info?.isMeaningful != true { homeChoice = nil }
    }

    // MARK: - The floating player

    /// A small player that floats above your windows (where you drag it) while something is playing.
    var floatingPlayerOn: Bool {
        get { defaults.object(forKey: "floatingPlayerOn") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "floatingPlayerOn"); objectWillChange.send() }
    }

    enum FloatingSize: Int { case compact, full, large }

    /// Small (cover, title, play), medium (adds skip and the progress line) or large (the cover fills the card).
    /// A double click steps to the next one and the third goes back to small. Small until you choose.
    var floatingSize: FloatingSize {
        get {
            if let v = defaults.object(forKey: "floatingSize") as? Int, let s = FloatingSize(rawValue: v) { return s }
            if let old = defaults.object(forKey: "floatingCompact") as? Bool { return old ? .compact : .full }   // from before there were three
            return .compact
        }
        set { defaults.set(newValue.rawValue, forKey: "floatingSize"); objectWillChange.send() }
    }
    func nextFloatingSize() {
        switch floatingSize {
        case .compact: floatingSize = .full
        case .full: floatingSize = .large
        case .large: floatingSize = .compact
        }
    }
    /// The two-way view of the size that older code and tests use.
    var floatingCompact: Bool {
        get { floatingSize == .compact }
        set { floatingSize = newValue ? .compact : .full }
    }

    /// Set by the floating player: pulls it out of the notch and onto the pointer.
    var onTearOff: (() -> Void)?

    /// The player card was dragged down out of the notch: the floating player takes over, under the pointer.
    func tearOffPlayer() {
        guard nowPlaying?.isMeaningful == true else { return }
        floatingPlayerOn = true
        onTearOff?()
        hovering = false
    }

    // MARK: - The floating basket

    /// Files dropped in the basket also go to the notch shelf (on: one shared list, the basket just shows it).
    /// Off: the basket keeps its own files, separate from the shelf.
    var basketSendsToShelf: Bool {
        get { defaults.object(forKey: "basketSendsToShelf") as? Bool ?? false }
        set {
            let was = basketSendsToShelf
            defaults.set(newValue, forKey: "basketSendsToShelf")
            if newValue, !was, !basketStore.items.isEmpty {         // switching to "send to the shelf": what was kept apart joins it
                shelf.add(basketStore.items.compactMap { basketStore.url(for: $0) })
                basketStore.clear()
            }
            objectWillChange.send()
        }
    }

    /// Moves files from the basket's own list onto the shelf (only matters while the two are separate).
    func sendToShelf(_ ids: [UUID]) {
        guard !basketSendsToShelf else { return }
        let items = basketStore.items.filter { ids.contains($0.id) }
        let urls = items.compactMap { basketStore.url(for: $0) }
        guard !urls.isEmpty else { return }
        shelf.add(urls)
        for i in items { basketStore.remove(i.id) }
        selection.prune(keeping: basketStore.items.map(\.id))
    }

    /// The list the basket shows and drops into.
    var basketList: ShelfStore { basketSendsToShelf ? shelf : basketStore }

    /// Whichever list a file is on (the shelf when it is on neither).
    func store(containing id: UUID) -> ShelfStore {
        basketStore.items.contains { $0.id == id } ? basketStore : shelf
    }

    /// A basket that appears at the pointer when you shake the mouse while dragging files.
    var basketEnabled: Bool {
        get { defaults.object(forKey: "basketEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "basketEnabled"); objectWillChange.send() }
    }

    /// Seconds after the last drop before the basket hides itself; 0 means it stays until you close it.
    var basketHideSeconds: Double {
        get { defaults.object(forKey: "basketHideSeconds") as? Double ?? 5 }
        set { defaults.set(newValue, forKey: "basketHideSeconds"); objectWillChange.send() }
    }

    // MARK: - Shelf controls

    /// Take a file off the shelf once you have dragged it out and dropped it somewhere (the file itself is never touched).
    var shelfRemoveAfterDragOut: Bool {
        get { defaults.object(forKey: "shelfRemoveAfterDragOut") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "shelfRemoveAfterDragOut"); objectWillChange.send() }
    }
    /// Days a file may stay on the shelf; 0 means until you remove it.
    var shelfKeepDays: Int {
        get { defaults.object(forKey: "shelfKeepDays") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "shelfKeepDays"); objectWillChange.send(); pruneShelf() }
    }
    /// Open the shelf by itself when you drag files toward the notch.
    var shelfOpensOnDrag: Bool {
        get { defaults.object(forKey: "shelfOpensOnDrag") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shelfOpensOnDrag"); objectWillChange.send() }
    }
    /// How firmly the mouse must be shaken to bring up the basket: easy, normal or firm.
    var basketShake: ShakeDetector.Strength {
        get { ShakeDetector.Strength(rawValue: defaults.string(forKey: "basketShake") ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "basketShake"); objectWillChange.send() }
    }

    func pruneShelf(now: Date = Date()) {
        guard shelfKeepDays > 0 else { return }
        shelf.prune(olderThan: TimeInterval(shelfKeepDays) * 86_400, now: now)
        basketStore.prune(olderThan: TimeInterval(shelfKeepDays) * 86_400, now: now)
    }

    /// A drag of a shelf file out into another app has ended.
    func dragOutEnded(_ itemID: UUID, droppedSomewhere: Bool) { dragOutEnded([itemID], droppedSomewhere: droppedSomewhere) }

    func dragOutEnded(_ itemIDs: [UUID], droppedSomewhere: Bool) {
        guard droppedSomewhere, shelfRemoveAfterDragOut else { return }
        for id in itemIDs { store(containing: id).remove(id); selection.ids.remove(id) }
    }

    /// A click on a file, with the Command and Shift keys as they are right now.
    func clickFile(_ id: UUID, in list: ShelfStore, command: Bool? = nil, shift: Bool? = nil) {
        let flags = NSEvent.modifierFlags
        selection.click(id, order: list.items.map(\.id), command: command ?? flags.contains(.command), shift: shift ?? flags.contains(.shift))
    }

    /// Adds files to a list and selects exactly what is new, so it can be dragged on together.
    @discardableResult
    func add(_ urls: [URL], to list: ShelfStore) -> Int {
        let before = Set(list.items.map(\.id))
        let n = list.add(urls)
        if n > 0 { selection.select(Set(list.items.map(\.id)).subtracting(before)) }
        return n
    }

    /// Zips the selected files into one archive next to the first. Runs in the background like the other actions.
    var zipRunner: ([URL], @escaping ProgressSink) async throws -> ActionResult = { urls, progress in
        try await Archive.zip(urls, progress)
    }

    func startZip(_ items: [ShelfItem]) {
        guard let first = items.first, items.count > 1, job(for: first.id) == nil else { return }
        let home = store(containing: first.id)
        let urls = items.compactMap { home.url(for: $0) }
        guard urls.count == items.count else { return }
        let label = "\(urls.count) files"
        let job = Job(itemID: first.id, fileName: label, verb: "Zipping", fraction: nil, status: "Starting…")
        jobs.append(job)
        let jid = job.id
        let run = zipRunner
        Task { [weak self] in
            do {
                let result = try await run(urls) { p in Task { @MainActor in self?.updateJob(jid, p) } }
                self?.finishJob(jid, .done(result, source: label))
            } catch {
                self?.finishJob(jid, .failed(error.localizedDescription, source: label))
            }
        }
    }

    // MARK: - Ask this file

    /// The shelf file whose question box is open (the island then keeps open and takes the keyboard).
    @Published var asking: UUID?
    private var askers: [UUID: FileAsker] = [:]

    func asker(for item: ShelfItem) -> FileAsker? {
        if let a = askers[item.id] { return a }
        guard let url = shelf.url(for: item), FileAsker.canAsk(FileKind.of(url)) else { return nil }
        let a = FileAsker(url: url)
        askers[item.id] = a
        return a
    }

    func startAsking(_ item: ShelfItem) { if asker(for: item) != nil { asking = item.id } }
    func stopAsking() { asking = nil }

    // MARK: - The living edge light

    enum GlowLevel: String, CaseIterable, Identifiable {
        case off, subtle, normal, vivid
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// How much of the full glow to draw (1 is the standard look).
        var factor: Double {
            switch self {
            case .off: 0
            case .subtle: 0.5
            case .normal: 1
            case .vivid: 1.45
            }
        }
    }

    var glowLevel: GlowLevel {
        get { GlowLevel(rawValue: defaults.string(forKey: "glowLevel") ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "glowLevel"); objectWillChange.send() }
    }

    /// What the open island is made of: black like the hardware notch (the default), or Liquid Glass.
    enum IslandStyle: String, CaseIterable, Identifiable {
        case black, glass
        var id: String { rawValue }
        var title: String { self == .black ? "Black" : "Liquid Glass" }
    }

    var islandStyle: IslandStyle {
        get { IslandStyle(rawValue: defaults.string(forKey: "islandStyle") ?? "") ?? .black }
        set { defaults.set(newValue.rawValue, forKey: "islandStyle"); objectWillChange.send() }
    }

    // MARK: - Caffeine

    let caffeine = Caffeine()

    func setCaffeine(_ d: Caffeine.Duration?) {
        if let d { caffeine.start(d) } else { caffeine.stop() }
        showFlash(Flash(symbol: caffeine.active ? "cup.and.saucer.fill" : "moon.zzz.fill",
                        text: caffeine.active ? "Awake" : "Can sleep", good: true), seconds: 1.8)
        objectWillChange.send()
    }

    // MARK: - Clean desktop (for screen recordings)

    @Published private(set) var desktopHidden = DesktopVisibility.hidden

    func refreshDesktop() { desktopHidden = DesktopVisibility.hidden }

    func setDesktopHidden(_ hide: Bool) {
        DesktopVisibility.set(hidden: hide, restartFinder: true)
        desktopHidden = DesktopVisibility.hidden
        showFlash(Flash(symbol: desktopHidden ? "eye.slash.fill" : "eye.fill",
                        text: desktopHidden ? "Desktop hidden" : "Desktop shown", good: true), seconds: 1.4)
    }

    func sendMedia(_ c: MediaCommand) { mediaSend?(c) }
    func seekMedia(to seconds: Double) { mediaSeek?(seconds) }

    // MARK: - File actions on the shelf

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let itemID: UUID
        let fileName: String
        let verb: String             // "Transcribing"
        var fraction: Double?
        var status: String
        let started = Date()
    }

    enum Outcome2: Equatable {
        case done(ActionResult, source: String)
        case failed(String, source: String)
    }

    @Published var jobs: [Job] = []
    @Published var outcome: Outcome2?
    @Published var outcomeStamp = UUID()
    private var outcomeTask: Task<Void, Never>?

    func job(for itemID: UUID) -> Job? { jobs.first { $0.itemID == itemID } }

    static func verb(for actionID: String) -> String {
        switch actionID.components(separatedBy: ":")[0] {
        case "removeBackground": "Removing background"
        case "extractText": "Reading text"
        case "image", "audio": "Converting"
        case "transcribe": "Transcribing"
        case "transcribeTranslate": "Transcribing"
        case "translate": "Translating"
        case "summarize": "Summarizing"
        default: "Working"
        }
    }

    /// Runs an action on a shelf file in the background. Progress shows on the file and beside the notch.
    /// `runner` can be replaced in tests.
    var runner: (String, URL, @escaping ProgressSink) async throws -> ActionResult = { id, url, sink in
        try await FileActions.run(id, on: url, progress: sink)
    }

    func startAction(_ actionID: String, on item: ShelfItem) {
        let home = store(containing: item.id)
        guard job(for: item.id) == nil, home.items.contains(where: { $0.id == item.id }), let url = home.url(for: item) else { return }
        let job = Job(itemID: item.id, fileName: item.name, verb: Self.verb(for: actionID), fraction: nil, status: "Starting…")
        jobs.append(job)
        let jid = job.id
        let run = runner
        Task { [weak self] in
            do {
                let result = try await run(actionID, url) { p in
                    Task { @MainActor in self?.updateJob(jid, p) }
                }
                self?.finishJob(jid, .done(result, source: item.name))
            } catch {
                self?.finishJob(jid, .failed(error.localizedDescription, source: item.name))
            }
        }
    }

    private func updateJob(_ id: UUID, _ p: ActionProgress) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].fraction = p.fraction.map { min(max($0, 0), 1) } ?? jobs[i].fraction
        jobs[i].status = p.status
    }

    private func finishJob(_ id: UUID, _ outcome: Outcome2) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: i)
        if case .done(let result, _) = outcome { store(containing: job.itemID).add(result.files) }     // results are ready to drag out, in the same place as the original
        showOutcome(outcome)
        if Date().timeIntervalSince(job.started) >= 15 {                        // took a while: tell the Mac as well
            switch outcome {
            case .done(let r, let source): Notifier.post(title: r.title, body: source)
            case .failed(let m, let source): Notifier.post(title: "Could not finish \(source)", body: m)
            }
        }
    }

    func showOutcome(_ o: Outcome2, seconds: Double = 14) {
        outcome = o
        outcomeStamp = UUID()
        outcomeTask?.cancel()
        outcomeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.outcome = nil }
        }
    }

    func dismissOutcome() {
        outcomeTask?.cancel()
        outcome = nil
    }

    func dropFiles(_ urls: [URL]) -> Bool {
        let n = add(urls, to: shelf)
        homeChoice = .shelf
        // the files were dropped on the open shelf: it stays open (the usual close rules apply once the pointer leaves),
        // so you can act on the file at once instead of pointing at the notch again
        if n > 0 { hovering = true }
        return n > 0
    }

    deinit { clock?.invalidate() }

    func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClock() }
        }
    }

    private func refreshClock() {
        tick = Date()
        nudgePulse()
        pruneShelf()
        let cutoff = Date().addingTimeInterval(-3600)
        sessions = sessions.filter { $0.value.lastEvent > cutoff }
    }

    // MARK: - Settings that the user can switch

    var sortWithAppleIntelligence: Bool {
        get { defaults.object(forKey: "sortWithAI") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sortWithAI"); objectWillChange.send() }
    }

    /// What a notification card says: the message as sent (the default), or Apple Intelligence's short summary.
    enum NotificationText: String, CaseIterable, Identifiable {
        case full, summary
        var id: String { rawValue }
        var title: String { self == .full ? "Full message" : "Short summary" }
    }

    /// Messages shorter than this are always shown word for word: a summary would not be shorter.
    static let summaryMinLength = 110

    var notificationText: NotificationText {
        get { NotificationText(rawValue: defaults.string(forKey: "notificationText") ?? "") ?? .full }
        set { defaults.set(newValue.rawValue, forKey: "notificationText"); objectWillChange.send() }
    }
    var respectFocus: Bool {
        get { defaults.object(forKey: "respectFocus") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "respectFocus"); objectWillChange.send() }
    }
    /// Minutes Claude may wait for an answer before the island reminds you; 0 switches the reminder off.
    var nudgeAfterMinutes: Int {
        get { defaults.object(forKey: "nudgeAfterMinutes") as? Int ?? 3 }
        set { defaults.set(min(max(newValue, 0), 30), forKey: "nudgeAfterMinutes"); objectWillChange.send() }
    }
    /// True once the first waiting approval or question is older than the chosen time.
    func isNudging(at now: Date = Date()) -> Bool {
        guard nudgeAfterMinutes > 0, let first = pending.first else { return false }
        return now.timeIntervalSince(first.request.receivedAt) >= Double(nudgeAfterMinutes) * 60
    }
    /// One calm pulse of the edge light. `force` is for coming back to the Mac, otherwise at most one every 30 s.
    func nudgePulse(force: Bool = false, at now: Date = Date()) {
        guard isNudging(at: now), force || now.timeIntervalSince(lastPulse) >= 30 else { return }
        lastPulse = now
        pulsing = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.pulsing = false
        }
    }
    /// The Mac woke up or was unlocked: if Claude is still waiting, draw the eye to it.
    func macReturned() { nudgePulse(force: true) }

    /// Claude finishing something quick is not worth a card; long tasks are.
    var finishedCardAfter: TimeInterval { 15 }

    // MARK: - What the island shows

    var current: Pending? { pending.first }

    var liveCount: Int { sessions.values.filter(\.isLive).count }

    /// From the "Claude finished" card: brings Claude's terminal tab to the front and closes the card.
    func goToTerminal(_ f: ClaudeFinish) {
        guard let t = f.terminal else { return }
        dismissFinished()
        TerminalJump.focus(t)
    }

    var liveSession: ClaudeSession? {
        sessions.values.filter(\.isLive).max { $0.lastEvent < $1.lastEvent }
    }

    var state: IslandState {
        if !pending.isEmpty { return .approval }
        if toast != nil { return .notification }
        if finished != nil { return .finished }
        if outcome != nil { return .result }
        if hovering || dragging { return .overview }
        if hud != nil || flash != nil || liveSession != nil || !jobs.isEmpty || musicWingsOn { return .wings }
        return .closed
    }
    var isOpen: Bool { [.approval, .notification, .finished, .result, .overview].contains(state) }

    // MARK: - Claude Code: permission requests

    func handle(json: [String: Any], connection: HookConnection) {
        let tool = json["tool_name"] as? String ?? "a tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let cwd = Self.projectDir(json)
        let d = RequestDescriber.describe(tool: tool, input: input)
        var request = ApprovalRequest(
            sessionID: json["session_id"] as? String ?? "unknown",
            tool: tool, headline: d.headline, detail: d.detail,
            cwd: cwd, branch: GitBranch.read(from: cwd), risk: d.risk,
            suggestions: json["permission_suggestions"] as? [[String: Any]] ?? [])
        request.input = input
        pending.append(Pending(request: request, connection: connection))
        noteTerminal(request.sessionID, cwd: cwd, json)
        touchSession(request.sessionID, cwd: cwd) { $0.status = .waiting }
        let id = request.id
        connection.onClose = { [weak self] in self?.dismiss(id: id) }
        if !request.isQuestion { requestExplanation(for: request) }     // a question explains itself
    }

    // MARK: - Claude's own questions

    /// The options picked so far on the question card on screen, by question text.
    @Published var questionPicks: [String: [String]] = [:]

    func pick(_ option: ClaudeQuestion.Option, in q: ClaudeQuestion) {
        var chosen = questionPicks[q.question] ?? []
        if q.multiSelect {
            if let i = chosen.firstIndex(of: option.label) { chosen.remove(at: i) } else { chosen.append(option.label) }
        } else {
            chosen = [option.label]
        }
        questionPicks[q.question] = chosen
    }

    /// Every question has at least one pick.
    var questionsAnswered: Bool {
        guard let qs = current?.request.questions, !qs.isEmpty else { return false }
        return qs.allSatisfy { !(questionPicks[$0.question] ?? []).isEmpty }
    }

    /// Sends the picks to Claude as its question tool's answers.
    func answerQuestions() {
        guard let item = pending.first, item.request.isQuestion, questionsAnswered else { return }
        pending.removeFirst()
        let r = item.request
        let updated = ClaudeQuestion.updatedInput(original: r.input, questions: r.questions, picks: questionPicks)
        let body: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                          "decision": ["behavior": "allow", "updatedInput": updated]]]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        item.connection.reply(String(decoding: data, as: UTF8.self))
        questionPicks = [:]
        record(r, .allowed)
        touchSession(r.sessionID, cwd: r.cwd) { $0.status = .working }
        if pending.isEmpty && !hovering { showFlash(Flash(symbol: "checkmark", text: "Answered", good: true)) }
    }

    /// Gives the question back to the terminal: Notch+ answers nothing, so Claude Code asks there as usual.
    func answerQuestionsInTerminal() {
        guard let item = pending.first, item.request.isQuestion else { return }
        pending.removeFirst()
        item.connection.reply("{}")
        questionPicks = [:]
        record(item.request, .answeredElsewhere)
        touchSession(item.request.sessionID, cwd: item.request.cwd) { $0.status = .waiting }
    }

    private func requestExplanation(for request: ApprovalRequest) {
        guard let explain else { return }
        explaining.insert(request.id)
        Task { [weak self] in
            let text = await explain(request)
            await MainActor.run {
                guard let self else { return }
                self.explaining.remove(request.id)
                if let text, !text.isEmpty { self.explanations[request.id] = text }
            }
        }
    }

    func answer(allow: Bool, always: Bool = false) {
        guard let item = pending.first else { return }
        // a question is not a yes or no: the keyboard shortcuts send the picks, or hand it to the terminal
        if item.request.isQuestion {
            if allow { answerQuestions() } else { answerQuestionsInTerminal() }
            return
        }
        pending.removeFirst()
        let r = item.request
        var decision: [String: Any]
        let outcome: Outcome
        if allow {
            decision = ["behavior": "allow"]
            if always, r.canAllowAlways { decision["updatedPermissions"] = r.suggestions }
            outcome = (always && r.canAllowAlways) ? .allowedAlways : .allowed
        } else {
            decision = ["behavior": "deny", "message": "Denied from Notch+"]
            outcome = .denied
        }
        let body: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        item.connection.reply(String(decoding: data, as: UTF8.self))
        record(r, outcome)
        touchSession(r.sessionID, cwd: r.cwd) { $0.status = allow ? .working : .idle }
        explanations.removeValue(forKey: r.id)
        if pending.isEmpty && !hovering {
            showFlash(Flash(symbol: allow ? "checkmark" : "xmark", text: outcome.short, good: allow))
        }
    }

    /// The hook went away (answered in the terminal, or Claude stopped).
    func dismiss(id: UUID) {
        guard let i = pending.firstIndex(where: { $0.request.id == id }) else { return }
        if i == 0 { questionPicks = [:] }
        let r = pending.remove(at: i).request
        record(r, .answeredElsewhere)
        touchSession(r.sessionID, cwd: r.cwd) { $0.status = .working }
        explanations.removeValue(forKey: r.id)
    }

    /// Claude Code does not hang up the hook when you answer in the terminal, but it does report that the tool
    /// finished (or that the turn moved on). Then the waiting card is stale: close it and let the hook end.
    /// With a tool name only the matching request goes; without one, every waiting request of that session.
    func settleElsewhere(session: String, tool: String?, input: [String: Any]?) {
        let matches = pending.filter { $0.request.sessionID == session && (tool == nil || $0.request.tool == tool) }
        var chosen = matches
        if tool != nil {
            let exact = matches.first { input != nil && NSDictionary(dictionary: $0.request.input).isEqual(to: input!) }
            chosen = [exact ?? matches.first].compactMap { $0 }
        }
        for m in chosen {
            m.connection.reply("{}")
            dismiss(id: m.request.id)
        }
    }

    private func record(_ r: ApprovalRequest, _ outcome: Outcome) {
        history.insert(HistoryEntry(headline: r.headline, detail: r.detail, outcome: outcome), at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
    }

    /// Volume and brightness beside the notch while you change them.
    var showLevels: Bool {
        get { defaults.object(forKey: "showLevels") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showLevels"); if !newValue { hud = nil }; objectWillChange.send() }
    }

    /// Charger in or out, or the battery running low, beside the notch.
    func showPower(_ e: PowerEvent) {
        guard showLevels else { return }
        switch e {
        case .pluggedIn(let p): showFlash(Flash(symbol: "bolt.fill", text: "\(p)%", good: true), seconds: 2.4)
        case .unplugged(let p): showFlash(Flash(symbol: "battery.50percent", text: "\(p)%", good: true), seconds: 2.4)
        case .low(let p): showFlash(Flash(symbol: "battery.25percent", text: "\(p)% left", good: false), seconds: 4)
        case .critical(let p): showFlash(Flash(symbol: "battery.0percent", text: "\(p)% left", good: false), seconds: 5)
        }
    }

    func showHUD(_ r: HUDReading, seconds: Double = 1.5) {
        guard showLevels else { return }
        hud = r
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.hud = nil }
        }
    }

    func showFlash(_ f: Flash, seconds: Double = 1.6) {
        flash = f
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    // MARK: - Claude Code: live status from hook events

    /// The session's project folder (Claude Code's own, sent by the hook script), else the folder it is in now.
    static func projectDir(_ json: [String: Any]) -> String {
        (json["_notch_project_dir"] as? String) ?? (json["cwd"] as? String ?? "")
    }

    /// Remembers which terminal a session runs in, to jump back to it from the sessions list.
    private func noteTerminal(_ id: String, cwd: String, _ json: [String: Any]) {
        guard let t = TerminalRef(json), sessions[id]?.terminal != t else { return }
        touchSession(id, cwd: cwd) { $0.terminal = t }
    }

    private func touchSession(_ id: String, cwd: String, _ change: (inout ClaudeSession) -> Void) {
        var s = sessions[id] ?? ClaudeSession(id: id, cwd: cwd)
        if !cwd.isEmpty, cwd != s.cwd || s.branch == nil { s.cwd = cwd; s.branch = GitBranch.read(from: cwd) }
        s.lastEvent = Date()
        change(&s)
        sessions[id] = s
    }

    func handleEvent(_ json: [String: Any]) {
        guard let name = json["hook_event_name"] as? String else { return }
        let id = json["session_id"] as? String ?? "unknown"
        let cwd = Self.projectDir(json)
        noteTerminal(id, cwd: cwd, json)
        switch name {
        case "SessionStart":
            touchSession(id, cwd: cwd) { $0.status = .idle; $0.tool = nil }
        case "UserPromptSubmit":
            settleElsewhere(session: id, tool: nil, input: nil)
            touchSession(id, cwd: cwd) { $0.status = .working; $0.tool = nil; $0.turnStart = Date() }
        case "PreToolUse":
            let tool = json["tool_name"] as? String
            touchSession(id, cwd: cwd) {
                $0.status = .working; $0.tool = tool
                if $0.turnStart == nil { $0.turnStart = Date() }
            }
        case "PostToolUse":
            settleElsewhere(session: id, tool: json["tool_name"] as? String, input: json["tool_input"] as? [String: Any])
            touchSession(id, cwd: cwd) { $0.status = .working; $0.tool = nil }
        case "Notification":
            let kind = json["notification_type"] as? String ?? ""
            if kind == "permission_prompt" || kind == "idle_prompt" || kind == "elicitation_dialog" {
                touchSession(id, cwd: cwd) { $0.status = .waiting }
            }
        case "Stop":
            settleElsewhere(session: id, tool: nil, input: nil)
            var duration: TimeInterval?
            var project = ""
            var branch: String?
            var terminal: TerminalRef?
            touchSession(id, cwd: cwd) {
                if let t = $0.turnStart { duration = Date().timeIntervalSince(t) }
                $0.status = .done; $0.tool = nil; $0.turnStart = nil
                $0.lastReply = Self.replyPreview(json["last_assistant_message"] as? String)
                project = $0.project; branch = $0.branch; terminal = $0.terminal
            }
            let finish = ClaudeFinish(project: project, branch: branch, duration: duration,
                                      message: Self.firstSentence(json["last_assistant_message"] as? String), terminal: terminal)
            finishedLog.insert(finish, at: 0)
            if finishedLog.count > 10 { finishedLog.removeLast(finishedLog.count - 10) }
            if (duration ?? 0) >= finishedCardAfter {
                showFinished(finish)
            }
        case "SessionEnd":
            settleElsewhere(session: id, tool: nil, input: nil)
            sessions.removeValue(forKey: id)
        default:
            break
        }
    }

    func showFinished(_ f: ClaudeFinish, seconds: Double = 7) {
        finished = f
        finishedTask?.cancel()
        finishedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.finished = nil }
        }
    }

    func dismissFinished() {
        finishedTask?.cancel()
        finished = nil
    }

    /// The start of Claude's answer on one line, for the sessions list.
    static func replyPreview(_ text: String?) -> String? {
        guard let t = text?.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t.count > 220 ? String(t.prefix(217)) + "..." : t
    }

    static func firstSentence(_ text: String?) -> String? {
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: "\n", with: " ")
        if let r = t.range(of: ". ") ?? t.range(of: "! ") ?? t.range(of: "? ") {
            t = String(t[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return t.count > 160 ? String(t.prefix(157)) + "..." : t
    }

    // MARK: - Notifications from other apps

    /// New notifications from the database, oldest first. Every app shows unless its choice in Settings
    /// says otherwise (or a Focus is on and Notch+ respects it). Apple Intelligence never decides what
    /// shows: the card opens at once, and its label and one-line summary are added when they are ready.
    /// Show Messages as soon as they arrive (read from Messages' own database) instead of when macOS stores the notification.
    var instantMessages: Bool {
        get { defaults.object(forKey: "instantMessages") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "instantMessages"); objectWillChange.send() }
    }
    private var shownGuids: [String] = []
    private var shownGuidSet = Set<String>()

    func receive(_ items: [RawNotification]) {
        for raw in items {
            let name = AppLookup.name(for: raw.bundleID)
            if !NotificationRules.isOwn(raw.bundleID) {
                var seen = rules.seenApps
                if seen[raw.bundleID] != name { seen[raw.bundleID] = name; rules.seenApps = seen }
            }
            var mode = rules.mode(for: raw.bundleID)
            guard mode != .ignore else { continue }
            if mode == .show, respectFocus, focusIsOn() { mode = .quiet }
            // the same message can arrive twice (at once from Messages' database, then as macOS's notification record): show it once
            if let g = raw.guid {
                if shownGuidSet.contains(g) { continue }
                shownGuidSet.insert(g); shownGuids.append(g)
                if shownGuids.count > 300 { shownGuidSet.remove(shownGuids.removeFirst()) }
            }

            let note = CapturedNotification(raw: raw, appName: name)
            notifications.insert(note, at: 0)
            if notifications.count > 30 { notifications.removeLast(notifications.count - 30) }
            if mode == .show { showToast(note) } else { quietUnseen += 1 }
            let wantsSummary = notificationText == .summary && (note.detail?.count ?? 0) >= Self.summaryMinLength
            if sortWithAppleIntelligence || wantsSummary, let triage {
                Task { [weak self] in
                    let result = await triage(raw)
                    await MainActor.run { self?.label(note.id, with: result) }
                }
            }
        }
    }

    /// Adds Apple Intelligence's label and summary to a notification already in the list (and on screen).
    private func label(_ id: UUID, with triage: TriageResult?) {
        guard let triage else { return }
        let priority = sortWithAppleIntelligence ? triage.priority : nil
        let summary = notificationText == .summary ? triage.summary : nil
        if let i = notifications.firstIndex(where: { $0.id == id }) {
            notifications[i].priority = priority
            notifications[i].summary = summary
        }
        if toast?.id == id {
            toast?.priority = priority
            toast?.summary = summary
        }
        if let q = toastQueue.firstIndex(where: { $0.note.id == id }) {
            toastQueue[q].note.priority = priority
            toastQueue[q].note.summary = summary
        }
    }

    /// Shows a notification card. If one is already on screen, the new one waits its turn (nothing is
    /// lost when two arrive together); the card says how many are waiting.
    func showToast(_ n: CapturedNotification, seconds: Double = 6) {
        if toast != nil {
            toastQueue.append((n, seconds))
            return
        }
        present(n, seconds: seconds)
    }

    private func present(_ n: CapturedNotification, seconds: Double) {
        toast = n
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.dismissToast() }
        }
    }

    // MARK: - Recent notifications

    /// Notifications kept quietly (a quiet app, or a Focus) that arrived since the Recent list was last opened.
    @Published var quietUnseen = 0

    func openRecent() {
        homeChoice = .recent
        quietUnseen = 0
    }

    func clearRecent() {
        notifications.removeAll()
        quietUnseen = 0
        homeChoice = nil
    }

    // MARK: - Replying to Messages from the card

    /// The notification being answered (its card stays open and takes the keyboard while you type).
    @Published var replying: UUID?
    @Published var replySuggestions: [String] = []
    @Published var replySending = false
    @Published var replyError: String?
    /// Sends a message (text, to handle). Real Messages in the app, a fake in tests.
    var sendMessage: (String, String) async throws -> Void = { _, _ in }
    /// Three suggested replies from Apple Intelligence, or none.
    var suggestReplies: ((CapturedNotification, String) async -> [String])?

    var messagesReplyOn: Bool {
        get { defaults.object(forKey: "messagesReply") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "messagesReply"); objectWillChange.send() }
    }

    /// A Messages notification from one person, with replying switched on.
    func canReply(_ n: CapturedNotification) -> Bool { messagesReplyOn && MessagesReply.handle(for: n.raw) != nil }

    func startReply(_ n: CapturedNotification) {
        guard canReply(n), let handle = MessagesReply.handle(for: n.raw) else { return }
        toastTask?.cancel()                 // the card waits while you type
        replying = n.id
        replyError = nil
        replySuggestions = []
        guard let suggestReplies else { return }
        Task { [weak self] in
            let s = await suggestReplies(n, handle)
            await MainActor.run { if self?.replying == n.id { self?.replySuggestions = s } }
        }
    }

    /// Sends what was typed. Only ever on the user's Send.
    func sendReply(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !replySending, let n = toast, n.id == replying, let handle = MessagesReply.handle(for: n.raw) else { return }
        replySending = true
        replyError = nil
        Task { [weak self] in
            do {
                try await self?.sendMessage(t, handle)
                await MainActor.run {
                    guard let self else { return }
                    self.replySending = false
                    self.dismissToast()
                    self.showFlash(Flash(symbol: "paperplane.fill", text: "Sent", good: true), seconds: 1.6)
                }
            } catch {
                await MainActor.run {
                    self?.replySending = false
                    self?.replyError = error.localizedDescription
                }
            }
        }
    }

    /// Leaving the reply without sending (clicked elsewhere): the card goes back to closing by itself.
    func leaveReply() {
        guard replying != nil, let n = toast else { replying = nil; return }
        replying = nil
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, self?.toast?.id == n.id { self?.dismissToast() }
        }
    }

    /// Closes the card on screen; the next waiting one, if any, takes its place.
    func dismissToast() {
        toastTask?.cancel()
        toast = nil
        replying = nil
        replySuggestions = []
        replyError = nil
        if !toastQueue.isEmpty {
            let next = toastQueue.removeFirst()
            present(next.note, seconds: next.seconds)
        }
    }

    /// How many notification cards are waiting behind the one on screen.
    var toastsWaiting: Int { toastQueue.count }

    func openSource(of n: CapturedNotification) {
        AppLookup.open(bundleID: n.bundleID)
        dismissToast()
    }

    /// "Mute app": from now on this app's notifications are kept quietly.
    func muteSource(of n: CapturedNotification) {
        rules.set(.quiet, for: n.bundleID)
        toastQueue.removeAll { $0.note.bundleID.lowercased() == n.bundleID.lowercased() }
        dismissToast()
        objectWillChange.send()
    }
}
