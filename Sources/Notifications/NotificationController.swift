import AppKit

/// Starts and stops the notification watcher and reports whether Notch+ is allowed to read the database.
@MainActor
final class NotificationController {
    let model: NotchModel
    private let path: String?
    private var watcher: NotificationWatcher?

    init(model: NotchModel, databasePath: String? = NotificationReader.databasePath()) {
        self.model = model
        self.path = databasePath
    }

    func start() {
        stop()
        guard let path else { model.notificationAccess = .needsFullDiskAccess; return }
        let reader = NotificationReader(path: path)
        guard reader.isReadable else { model.notificationAccess = .needsFullDiskAccess; return }
        let w = NotificationWatcher(reader: reader) { [weak self] raws in
            Task { @MainActor in self?.model.receive(raws) }
        }
        if w.start() {
            watcher = w
            model.notificationAccess = .granted
        } else {
            model.notificationAccess = .needsFullDiskAccess
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
