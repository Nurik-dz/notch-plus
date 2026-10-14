import AppKit
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
        // A restarted Finder comes back as the front app and would pull focus away from what you are doing (or recording):
        // remember the app that was in front and hand focus back to it once Finder is up again.
        let before = NSWorkspace.shared.frontmostApplication
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Finder"]
        p.standardError = FileHandle.nullDevice
        try? p.run()
        if let before, before.bundleIdentifier != "com.apple.finder" { returnFocus(to: before) }
        return true
    }

    /// Waits for the new Finder to appear, then re-activates the app that was in front before.
    private static func returnFocus(to app: NSRunningApplication) {
        Task { @MainActor in
            var seenFinder = false
            for _ in 0..<40 {                                           // up to about 4 seconds
                try? await Task.sleep(nanoseconds: 100_000_000)
                let finderUp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").contains { !$0.isTerminated }
                if finderUp, !seenFinder { seenFinder = true; continue }
                if seenFinder, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
                    bringBack(app)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    bringBack(app)                                      // once more in case Finder claimed it again
                    return
                }
            }
        }
    }

    /// Opening a running app by its location brings it to the front reliably (a plain activate() from a background app can be ignored).
    private static func bringBack(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { app.activate(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
