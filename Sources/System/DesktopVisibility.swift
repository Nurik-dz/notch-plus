import Foundation
import CoreFoundation

/// Hides or shows the files and folders on the desktop for screen recordings.
/// Finder draws the desktop, and it only re-reads its "create desktop" setting when it starts, so
/// turning it off or on restarts Finder (about a second; open Finder windows come back by themselves).
/// Checked on macOS 27: the preference "Show Items on Desktop" in the WindowManager domain is not
/// noticed by a running Finder, which is why this uses Finder's own setting.
enum DesktopVisibility {
    private static let domain = "com.apple.finder" as CFString
    private static let key = "CreateDesktop" as CFString

    /// Whether the desktop is hidden right now.
    static var hidden: Bool {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(key, domain) as? Bool) == false
    }

    /// Writes the setting; returns whether Finder has to be restarted to notice it.
    @discardableResult
    static func set(hidden: Bool, restartFinder: Bool = false) -> Bool {
        CFPreferencesSetAppValue(key, hidden ? kCFBooleanFalse : nil, domain)     // shown means the key is simply absent, as macOS ships
        CFPreferencesAppSynchronize(domain)
        guard restartFinder else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Finder"]
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return true
    }
}
