import AppKit

/// Starts and stops the notification watcher and reports whether Notch+ is allowed to read the database.
@MainActor
final class NotificationController {
    let model: NotchModel
    /// Where the database is; asked again on every retry (it can appear after Notch+ opens).
    private let locate: () -> String?
    private var watcher: NotificationWatcher?
    private var retry: Timer?

    init(model: NotchModel, databasePath: @autoclosure @escaping () -> String? = NotificationReader.databasePath()) {
        self.model = model
        self.locate = databasePath
    }

    /// Starts watching. Without access yet (Full Disk Access not granted, or granted after Notch+ opened,
    /// or lost because a rebuilt app counts as a new one), it checks again every few seconds and starts
    /// by itself the moment access works, so nobody has to quit and reopen Notch+.
    func start() {
        stop()
        if tryStart() { return }
        model.notificationAccess = .needsFullDiskAccess
        retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tryStart() else { return }
                self.retry?.invalidate(); self.retry = nil
            }
        }
    }

    private func tryStart() -> Bool {
        guard let path = locate() else { return false }
        let reader = NotificationReader(path: path)
        guard reader.isReadable else { return false }
        let w = NotificationWatcher(reader: reader) { [weak self] raws in
            Task { @MainActor in self?.model.receive(raws) }
        }
        guard w.start() else { return false }
        watcher = w
        startMessages()
        model.notificationAccess = .granted
        return true
    }

    /// The apps for the per-app list in Settings: every real app macOS has registered for notifications
    /// (system helpers that are not apps are left out), as bundle id and name.
    func registeredApps() -> [(id: String, name: String)] {
        guard let path = locate() else { return [] }
        let reader = NotificationReader(path: path)
        return reader.registeredApps().compactMap { id in
            guard id != NotificationRules.ownBundleID.lowercased(), !id.hasPrefix("_system_center_"),
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return nil }
            return (id: id, name: AppLookup.name(for: id))
        }
    }

    func stop() {
        retry?.invalidate(); retry = nil
        watcher?.stop()
        watcher = nil
        messages?.stop()
        messages = nil
    }

    /// Messages arrive in Messages' own database about a second after they are sent, macOS stores the notification only
    /// 8 to 13 seconds later: read the first, and the second is recognised by its id and skipped.
    private var messages: MessagesWatcher?
    private func startMessages() {
        let mw = MessagesWatcher()
        guard mw.open() else { return }
        mw.onNew = { [weak self] raws in
            Task { @MainActor in
                guard let self, self.model.instantMessages else { return }
                // with Messages in front macOS shows no banner (you are looking at the conversation), so neither do we
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.MobileSMS" { return }
                self.model.receive(raws)
            }
        }
        mw.start()
        messages = mw
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
