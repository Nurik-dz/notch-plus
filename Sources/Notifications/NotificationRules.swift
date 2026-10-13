import AppKit
import SwiftUI

/// A notification ready to show: the raw data plus the app's name and icon.
struct CapturedNotification: Identifiable, Equatable {
    let id = UUID()
    let raw: RawNotification
    let appName: String
    /// Filled in by Apple Intelligence when sorting is on.
    var priority: NotificationPriority?
    var summary: String?

    var bundleID: String { raw.bundleID }
    var headline: String { raw.title ?? raw.subtitle ?? appName }
    /// The second line: the subtitle when there is a title, then the body.
    var detail: String? {
        let parts = [raw.title != nil ? raw.subtitle : nil, raw.body].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }
    var date: Date { raw.date }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// What to do with notifications from one app.
enum NotificationMode: String, CaseIterable, Identifiable {
    case show     // open the island with it
    case quiet    // keep it in the recent list only
    case ignore   // drop it
    var id: String { rawValue }
    var label: String {
        switch self {
        case .show: "Show in notch"
        case .quiet: "Show quietly"
        case .ignore: "Ignore"
        }
    }
}

/// Per-app choices, saved in the app's own preferences.
final class NotificationRules {
    private let defaults: UserDefaults
    private let key = "notificationModes"
    private let seenKey = "notificationSeenApps"
    static let ownBundleID = "com.nurik.NotchPlus"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var modes: [String: String] { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }

    func mode(for bundleID: String) -> NotificationMode {
        if bundleID == Self.ownBundleID { return .ignore }
        if let saved = modes[bundleID], let m = NotificationMode(rawValue: saved) { return m }
        return .show
    }

    func set(_ mode: NotificationMode, for bundleID: String) {
        var m = modes
        m[bundleID] = mode.rawValue
        defaults.set(m, forKey: key)
    }

    /// Every app that has ever sent a notification (bundle id -> name), for the settings list.
    var seenApps: [String: String] {
        get { defaults.dictionary(forKey: seenKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: seenKey) }
    }
}

enum AppLookup {
    private static var cache: [String: NSImage] = [:]

    /// A readable app name for a bundle id such as "com.apple.dt.xcode" or "_system_center_:com.apple.x".
    static func name(for bundleID: String) -> String {
        let id = bundleID.components(separatedBy: ":").last ?? bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        let last = id.components(separatedBy: ".").last ?? id
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    static func icon(for bundleID: String) -> NSImage? {
        let id = bundleID.components(separatedBy: ":").last ?? bundleID
        if let c = cache[id] { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = image
        return image
    }

    /// The colour of the app's icon, used for the glow around its notifications.
    static func accent(for bundleID: String) -> Color {
        guard let icon = icon(for: bundleID) else { return Theme.blue }
        return ImageColor.dominant(of: icon, key: bundleID)
    }

    static func open(bundleID: String) {
        let id = bundleID.components(separatedBy: ":").last ?? bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
