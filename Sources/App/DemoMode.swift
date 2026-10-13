import Foundation
import Network
import notify

/// A scripted tour with made-up data, only when the app is started with NOTCH_DEMO set.
/// Shows every state in the notch without touching Claude Code or any real notification.
/// NOTCH_DEMO=1 plays the whole tour at launch. NOTCH_DEMO=wait plays nothing until told, one step at a time
/// (for screen recordings): `notifyutil -p notchplus.demo.status` (or .notification, .approval, .finish, .all).
@MainActor
enum DemoMode {
    static var isOn: Bool { ProcessInfo.processInfo.environment["NOTCH_DEMO"] != nil }
    private static let cwd = "/Users/you/Projects/Notch+"
    private static var tokens: [Int32] = []

    static func start(model: NotchModel) {
        if ProcessInfo.processInfo.environment["NOTCH_DEMO"] == "wait" {
            listen(model: model)
        } else {
            run(model: model)
        }
    }

    private static func listen(model: NotchModel) {
        let steps: [(String, @MainActor () -> Void)] = [
            ("status", { status(model) }),
            ("notification", { notification(model) }),
            ("approval", { approval(model) }),
            ("finish", { finish(model) }),
            ("all", { run(model: model) }),
        ]
        for (name, action) in steps {
            var token: Int32 = 0
            notify_register_dispatch("notchplus.demo.\(name)", &token, DispatchQueue.main) { _ in
                MainActor.assumeIsolated { action() }
            }
            tokens.append(token)
        }
    }

    // 1. Claude is working: live status beside the notch
    private static func status(_ model: NotchModel) {
        model.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "demo", "cwd": cwd])
        model.handleEvent(["hook_event_name": "PreToolUse", "session_id": "demo", "cwd": cwd, "tool_name": "Edit"])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            model.handleEvent(["hook_event_name": "PreToolUse", "session_id": "demo", "cwd": cwd, "tool_name": "Bash"])
        }
    }

    // 2. A notification from another app, sorted by Apple Intelligence
    private static func notification(_ model: NotchModel) {
        var mum = CapturedNotification(
            raw: RawNotification(recordID: 1, bundleID: "com.apple.MobileSMS", title: "Mum", subtitle: nil,
                                 body: "Are you coming for dinner tonight? Need to know by 5 please, I am cooking for everyone and still need to buy more.",
                                 date: Date()), appName: "Messages")
        mum.priority = .now
        mum.summary = "Mum needs to know by 5 if you come to dinner."
        model.notifications.insert(mum, at: 0)
        model.showToast(mum, seconds: 7)
    }

    // 3. A permission request, explained in plain words on this Mac
    private static func approval(_ model: NotchModel) {
        let json: [String: Any] = [
            "tool_name": "Bash", "session_id": "demo", "cwd": cwd,
            "tool_input": ["command": "git add -A && git commit -m \"Add live status and notifications\" && git push origin main"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "localSettings"]],
        ]
        model.handle(json: json, connection: HookConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp)))
    }

    // 4. Claude finishes a long task
    private static func finish(_ model: NotchModel) {
        model.sessions["demo"]?.turnStart = Date().addingTimeInterval(-134)
        model.handleEvent(["hook_event_name": "Stop", "session_id": "demo", "cwd": cwd,
                           "last_assistant_message": "I added live status, smarter notifications and the new look. All checks pass."])
    }

    static func run(model: NotchModel) {
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            await wait(2)
            status(model)
            await wait(8)
            notification(model)
            await wait(9)
            approval(model)
            // when it has been answered (or after a minute), Claude finishes
            var waited = 0.0
            while !model.pending.isEmpty && waited < 60 { await wait(0.5); waited += 0.5 }
            await wait(2.5)
            finish(model)
        }
    }
}
