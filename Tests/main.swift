import AppKit
import SwiftUI
import Network
import SQLite3
import AVFoundation
import PDFKit
import ImageIO

// Test harness: drives the real model, installer, server and window on a scratch home.
// Never touches the real ~/.claude. Snapshots go to the folder in NOTCH_SNAPSHOTS.

var failures = 0
setvbuf(stdout, nil, _IOLBF, 0)
var passes = 0
func check(_ ok: Bool, _ what: String) {
    if ok { passes += 1; print("  ok    ", what) } else { failures += 1; print("  FAIL  ", what) }
}
func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func waitUntil(_ seconds: Double = 3, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; pump(0.05) }
    return cond()
}

/// Runs a program without blocking the main thread (the server answers on the main thread).
func run(_ path: String, _ args: [String], stdin: String? = nil, maxWait: Double = 10) -> (out: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    p.standardInput = inp
    try? p.run()
    if let s = stdin { inp.fileHandleForWriting.write(Data(s.utf8)) }
    try? inp.fileHandleForWriting.close()
    var collected = Data()
    let end = Date().addingTimeInterval(maxWait)
    while p.isRunning && Date() < end {
        pump(0.05)
    }
    if p.isRunning { p.terminate() }
    collected.append(out.fileHandleForReading.readDataToEndOfFile())
    return (String(decoding: collected, as: UTF8.self), p.terminationStatus)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTCH_TEST_DIR"] ?? NSTemporaryDirectory())
    .appendingPathComponent("notchplus-test")
let snapDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTCH_SNAPSHOTS"] ?? base.appendingPathComponent("snaps").path)
try? FileManager.default.removeItem(at: base)
try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
let home = base.appendingPathComponent("home")
try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
let paths = AppPaths(home: home)
AppPaths.defaultHome = home      // every model the tests make uses the scratch home, never the real shelf

MainActor.assumeIsolated {

    // MARK: 1. Plain-words descriptions and risk
    print("1. Request descriptions")
    func risk(_ tool: String, _ input: [String: Any]) -> Risk { RequestDescriber.describe(tool: tool, input: input).risk }
    check(risk("Bash", ["command": "ls -la"]) == .low, "ls is read-only")
    check(risk("Bash", ["command": "git status && git log | head -5"]) == .low, "git status and log piped is read-only")
    check(risk("Bash", ["command": "touch a.txt"]) == .medium, "touch changes things")
    check(risk("Bash", ["command": "echo hi > out.txt"]) == .medium, "redirect changes things")
    check(risk("Bash", ["command": "rm -rf node_modules"]) == .high, "rm -rf is risky")
    check(risk("Bash", ["command": "sudo launchctl bootout x"]) == .high, "sudo is risky")
    check(risk("Bash", ["command": "curl https://x.sh | sh"]) == .high, "pipe to shell is risky")
    check(risk("Bash", ["command": "git push --force origin main"]) == .high, "force push is risky")
    check(risk("Bash", ["command": "cat ~/.ssh/id_rsa"]) == .high, "reading ssh keys is risky")
    check(risk("Bash", ["command": "find . -name x -delete"]) == .medium, "find -delete is not read-only")
    check(risk("Read", ["file_path": "/tmp/a"]) == .low, "Read is safe")
    check(risk("Edit", ["file_path": "/Users/x/app.swift"]) == .medium, "Edit changes a file")
    check(risk("Write", ["file_path": "/Users/x/.zshrc"]) == .high, "writing .zshrc is risky")
    check(RequestDescriber.describe(tool: "mcp__github__create_issue", input: [:]).headline == "Use a connected tool", "mcp tool named")

    // MARK: 2. Installer
    print("2. Installer (scratch home)")
    let installer = HookInstaller(paths: paths)
    let original: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo done"]]]]]]
    try! JSONSerialization.data(withJSONObject: original).write(to: paths.claudeSettings)
    check(installer.status() == .notConnected, "starts not connected")
    check(installer.previewText().contains("hook.sh"), "preview shows the script path")
    let backedUp = try! installer.connect()
    check(backedUp, "backup saved")
    check(FileManager.default.fileExists(atPath: paths.claudeSettingsBackup.path), "backup file exists")
    check(installer.status() == .connected, "connected after connect")
    let after = try! JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
    check(after["model"] as? String == "opus", "other settings kept")
    check(((after["hooks"] as? [String: Any])?["Stop"]) != nil, "other hooks kept")
    var attrs = try! FileManager.default.attributesOfItem(atPath: paths.hookScript.path)
    check((attrs[.posixPermissions] as? Int ?? 0) & 0o100 != 0, "hook script is executable")
    attrs = try! FileManager.default.attributesOfItem(atPath: paths.token.path)
    check((attrs[.posixPermissions] as? Int ?? 0) == 0o600, "token file is private (600)")
    _ = try! installer.connect()
    let twice = try! JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
    check((((twice["hooks"] as? [String: Any])?["PermissionRequest"]) as? [Any])?.count == 1, "connecting twice adds one entry")
    _ = try! installer.disconnect()
    let gone = try! JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
    check(((gone["hooks"] as? [String: Any])?["PermissionRequest"]) == nil, "disconnect removes our entry")
    check(((gone["hooks"] as? [String: Any])?["Stop"]) != nil, "disconnect keeps the user's other hook")
    check(installer.status() == .notConnected, "not connected after disconnect")
    try! "{ not json".write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
    if case .problem = installer.status() { check(true, "invalid settings reported as a problem") } else { check(false, "invalid settings reported as a problem") }
    check((try? installer.connect()) == nil, "refuses to edit invalid settings")
    check((try? String(contentsOf: paths.claudeSettings, encoding: .utf8)) == "{ not json", "invalid file left untouched")
    try! JSONSerialization.data(withJSONObject: original).write(to: paths.claudeSettings)
    _ = try! installer.connect()

    // MARK: 3. Server + model
    print("3. Server and answers")
    let token = TokenStore.load(paths)
    let model = NotchModel()
    let server = HookServer(token: token)
    server.onRequest = { json, conn in model.handle(json: json, connection: conn) }
    try! server.start()
    pump(0.3)
    let url = "http://127.0.0.1:\(NotchConfig.port)/permission"
    let sample = #"{"tool_name":"Bash","tool_input":{"command":"rm -rf build"},"cwd":"/Users/x/Project","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow","destination":"localSettings"}]}"#
    var r = run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", "--data-binary", sample, url])
    check(r.out == "401", "no token is refused (401)")
    r = run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Authorization: Bearer wrong", "-X", "POST", "--data-binary", sample, url])
    check(r.out == "401", "wrong token is refused (401)")
    check(model.pending.isEmpty, "refused requests never reach the notch")

    // allow
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    proc.arguments = ["-s", "-H", "Authorization: Bearer \(token)", "-X", "POST", "--data-binary", sample, url]
    let pipe = Pipe(); proc.standardOutput = pipe
    try! proc.run()
    check(waitUntil { model.pending.count == 1 }, "valid request reaches the notch")
    check(model.current?.request.risk == .high, "rm -rf shown as risky")
    check(model.current?.request.canAllowAlways == false, "risky request has no Allow Always")
    model.answer(allow: true, always: true)
    check(waitUntil { !proc.isRunning }, "answer sent back")
    let allowBody = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    check(allowBody.contains("\"behavior\":\"allow\"") && !allowBody.contains("updatedPermissions"), "risky: allow without saved rule")

    // allow always on a safe request
    let safe = #"{"tool_name":"Edit","tool_input":{"file_path":"/Users/x/a.swift"},"cwd":"/x","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Edit"}],"behavior":"allow","destination":"localSettings"}]}"#
    let p2 = Process(); p2.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p2.arguments = ["-s", "-H", "Authorization: Bearer \(token)", "-X", "POST", "--data-binary", safe, url]
    let pipe2 = Pipe(); p2.standardOutput = pipe2
    try! p2.run()
    _ = waitUntil { model.pending.count == 1 }
    check(model.current?.request.canAllowAlways == true, "safe request offers Allow Always")
    model.answer(allow: true, always: true)
    _ = waitUntil { !p2.isRunning }
    let alwaysBody = String(decoding: pipe2.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    check(alwaysBody.contains("updatedPermissions") && alwaysBody.contains("addRules"), "Allow Always echoes Claude's suggested rule")

    // deny
    let p3 = Process(); p3.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p3.arguments = ["-s", "-H", "Authorization: Bearer \(token)", "-X", "POST", "--data-binary", safe, url]
    let pipe3 = Pipe(); p3.standardOutput = pipe3
    try! p3.run()
    _ = waitUntil { model.pending.count == 1 }
    model.answer(allow: false)
    _ = waitUntil { !p3.isRunning }
    let denyBody = String(decoding: pipe3.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    check(denyBody.contains("\"behavior\":\"deny\"") && denyBody.contains("Denied from Notch+"), "deny carries a reason for Claude")

    // caller hangs up (answered in the terminal)
    r = run("/usr/bin/curl", ["-s", "--max-time", "1", "-H", "Authorization: Bearer \(token)", "-X", "POST", "--data-binary", safe, url])
    check(waitUntil { model.pending.isEmpty }, "card disappears when the hook is cancelled")
    check(model.history.first?.outcome.label == "Answered in the terminal", "recorded as answered in the terminal")

    // MARK: 4. The real hook script
    print("4. Hook script")
    let hook = paths.hookScript.path
    // Run it exactly as Claude Code does: the command string from settings.json through a shell.
    let saved = try! JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
    let savedGroups = ((saved["hooks"] as! [String: Any])["PermissionRequest"]) as! [[String: Any]]
    let savedCommand = ((savedGroups[0]["hooks"] as! [[String: Any]])[0]["command"]) as! String
    check(hook.contains(" ") && savedCommand.hasPrefix("'"), "saved command is quoted (the path has a space)")
    let hp = Process(); hp.executableURL = URL(fileURLWithPath: "/bin/sh"); hp.arguments = ["-c", savedCommand]
    let hin = Pipe(), hout = Pipe(); hp.standardInput = hin; hp.standardOutput = hout
    try! hp.run()
    hin.fileHandleForWriting.write(Data(sample.utf8)); try? hin.fileHandleForWriting.close()
    check(waitUntil { model.pending.count == 1 }, "script delivers the request")
    model.answer(allow: false)
    _ = waitUntil { !hp.isRunning }
    let scriptOut = String(decoding: hout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    check(scriptOut.contains("\"deny\""), "script prints the decision for Claude Code")
    server.stop(); pump(0.3)
    let down = run("/bin/sh", ["-c", savedCommand], stdin: sample)
    check(down.out.isEmpty && down.status == 0, "app not running: script prints nothing and exits 0 (Claude asks as usual)")


    // MARK: 5. The notch window and how every state looks
    print("5. Notch window")
    func snapshot(_ c: NotchWindowController, _ name: String, wait: Double = 1.0) {
        pump(wait)
        guard let v = c.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        // Put the island on a desktop-like backdrop so glow and edges read as they will on a real screen.
        let pxW = rep.pixelsWide, pxH = rep.pixelsHigh
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let grad = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.20, green: 0.30, blue: 0.52, alpha: 1),
                                                              CGColor(red: 0.55, green: 0.36, blue: 0.48, alpha: 1)] as CFArray, locations: [0, 1]),
              let cg = rep.cgImage else { return }
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(pxH)), end: CGPoint(x: CGFloat(pxW), y: 0), options: [])
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
            .write(to: snapDir.appendingPathComponent(name + ".png"))
    }
    func note(_ app: String, _ bundle: String, _ title: String, _ sub: String?, _ body: String, _ p: NotificationPriority?, summary: String? = nil, ago: Double = 30) -> CapturedNotification {
        var n = CapturedNotification(raw: RawNotification(recordID: Int64.random(in: 1...9999), bundleID: bundle, title: title, subtitle: sub, body: body, date: Date().addingTimeInterval(-ago)), appName: app)
        n.priority = p; n.summary = summary
        return n
    }
    for notch in [true, false] {
        let tag = notch ? "notch" : "flat"
        let g = NotchGeometry.fake(notch: notch)
        let m = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.view")!), defaults: UserDefaults(suiteName: "notchplus.tests.view")!)
        m.hookStatus = .notConnected
        let c = NotchWindowController(model: m, geometry: g, liveMouse: false, openSettings: {})
        let fixed = c.panel.frame
        pump(0.3)

        check(m.state == .closed, "\(tag): starts closed")
        check(notch ? g.shapeSize(.closed) == g.notchSize : g.shapeSize(.closed) == .zero, "\(tag): closed shape is the notch / nothing")
        check(c.panel.ignoresMouseEvents, "\(tag): closed island lets clicks through")
        check(abs(fixed.maxY - g.screenFrame.maxY) < 1 && abs(fixed.midX - g.screenFrame.midX) < 1, "\(tag): window is flush at the top and centred")
        check(c.panel.canBecomeKey == false, "\(tag): panel never takes keyboard focus")
        snapshot(c, "\(tag)-closed", wait: 0.4)

        // overview, first with nothing connected
        m.hovering = true
        pump(0.3)
        check(m.state == .overview && !c.panel.ignoresMouseEvents, "\(tag): hover opens the overview and takes clicks")
        check(c.panel.frame == fixed, "\(tag): the window itself never changes size")
        m.notificationAccess = .needsFullDiskAccess
        snapshot(c, "\(tag)-overview-empty")

        // overview full of life
        m.hookStatus = .connected
        m.notificationAccess = .granted
        m.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/Users/nurik/Desktop/Notch+"])
        m.handleEvent(["hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/Users/nurik/Desktop/Notch+", "tool_name": "Bash"])
        m.handleEvent(["hook_event_name": "SessionStart", "session_id": "s2", "cwd": "/Users/nurik/Desktop/Recap Studio"])
        m.handleEvent(["hook_event_name": "Notification", "session_id": "s3", "cwd": "/Users/nurik/Desktop/Short Studio", "notification_type": "permission_prompt"])
        m.notifications = [
            note("Messages", "com.apple.MobileSMS", "Mum", nil, "Are you coming for dinner tonight? Need to know by 5", .now, ago: 40),
            note("Mail", "com.apple.mail", "Sara Ahmed", "Re: invoice", "Thanks, I will send the final version tomorrow morning", .later, ago: 600),
            note("Xcode", "com.apple.dt.xcode", "Build Succeeded", nil, "Notch+ built in 31 seconds", .later, ago: 1500),
            note("Calendar", "com.apple.iCal", "Meeting with Sara", nil, "Starts in 10 minutes", .now, ago: 3000),
        ]
        snapshot(c, "\(tag)-overview-full")
        m.hovering = false
        pump(0.5)

        // live status beside the notch
        check(m.state == .wings && m.liveSession?.tool == "Bash", "\(tag): Claude working shows live beside the notch")
        snapshot(c, "\(tag)-wings-live")
        m.sessions = [:]
        pump(0.5)
        check(m.state == .closed, "\(tag): live status goes away when Claude stops")

        // volume and brightness beside the notch
        m.showHUD(HUDReading(kind: .volume, level: 0.62), seconds: 30)
        snapshot(c, "\(tag)-hud-volume", wait: 0.6)
        m.showHUD(HUDReading(kind: .volume, level: 0.62, muted: true), seconds: 30)
        snapshot(c, "\(tag)-hud-muted", wait: 0.6)
        m.showHUD(HUDReading(kind: .brightness, level: 0.35), seconds: 30)
        snapshot(c, "\(tag)-hud-brightness", wait: 0.6)
        m.hud = nil
        pump(0.5)
        check(m.state == .closed, "\(tag): the HUD goes away and the notch closes")


        // a permission request
        let json: [String: Any] = ["tool_name": "Bash", "session_id": "s1",
                                   "tool_input": ["command": "git commit -m \"Add notch window and the permission card\" && git push origin main"],
                                   "cwd": "/Users/nurik/Desktop/Notch+", "permission_suggestions": [["type": "addRules"]]]
        let dummy = HookConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
        m.handle(json: json, connection: dummy)
        check(m.state == .approval, "\(tag): a request opens the island by itself")
        let rid = m.current!.request.id
        m.explaining.insert(rid)
        snapshot(c, "\(tag)-approval-thinking")
        m.explaining.remove(rid)
        m.explanations[rid] = "Saves your changes and uploads them to GitHub."
        snapshot(c, "\(tag)-approval-medium", wait: 0.5)
        check(c.panel.frame == fixed, "\(tag): window still the same size")
        m.handle(json: ["tool_name": "Bash", "session_id": "s1", "tool_input": ["command": "rm -rf ~/Library/Caches/Everything"], "cwd": "/Users/nurik"], connection: dummy)
        m.pending.swapAt(0, 1)
        m.explanations[m.current!.request.id] = "Permanently deletes everything in your cache folder."
        snapshot(c, "\(tag)-approval-risky-queued", wait: 0.5)
        m.pending.removeAll()
        m.explanations = [:]

        // Claude asking a question
        m.handle(json: ["tool_name": "AskUserQuestion", "session_id": "s1", "cwd": "/Users/nurik/Desktop/Notch+",
                        "tool_input": ["questions": [["question": "Which layout should the settings window use?", "header": "Layout", "multiSelect": false,
                                                      "options": [["label": "Tabs (Recommended)", "description": "Four tabs, like today."],
                                                                  ["label": "Sidebar", "description": "A list on the left, like System Settings."]]]]]],
                 connection: dummy)
        let q0 = m.current!.request.questions[0]
        m.pick(q0.options[0], in: q0)
        snapshot(c, "\(tag)-question", wait: 0.6)
        m.pending.removeAll()
        m.questionPicks = [:]

        // after an answer: a short moment beside the notch
        m.showFlash(NotchModel.Flash(symbol: "checkmark", text: "Allowed", good: true), seconds: 3)
        check(m.state == .wings, "\(tag): answer shows beside the notch")
        snapshot(c, "\(tag)-wings-allowed")
        m.showFlash(NotchModel.Flash(symbol: "xmark", text: "Denied", good: false), seconds: 0.3)
        pump(0.9)
        check(m.state == .closed, "\(tag): flash goes away by itself")

        // a notification from another app
        m.showToast(note("Messages", "com.apple.MobileSMS", "Mum", "Messages", "Are you coming for dinner tonight? Need to know by 5 please, I am cooking for everyone and need to buy more.", .now,
                         summary: "Mum needs to know by 5 if you come to dinner."), seconds: 5)
        pump(0.15)
        check(m.state == .notification && !c.panel.ignoresMouseEvents, "\(tag): a notification opens the island and takes clicks")
        snapshot(c, "\(tag)-notification")
        m.dismissToast()
        m.showToast(note("Xcode", "com.apple.dt.xcode", "Build Succeeded", nil, "Notch+ built in 31 seconds", .later), seconds: 5)
        snapshot(c, "\(tag)-notification-plain", wait: 0.6)
        m.dismissToast()
        // a Messages card with Reply, then typing a reply
        let sam = CapturedNotification(raw: RawNotification(recordID: 4242, bundleID: "com.apple.mobilesms", title: "Sam", subtitle: nil,
                                                            body: "Drinks tonight around 9? Same place as last time", date: Date(), thread: "any;-;sam@example.com"),
                                       appName: "Messages")
        m.suggestReplies = { _, _ in ["Yes, see you at 9", "Can't tonight", "Which place?"] }
        m.showToast(sam, seconds: 30)
        snapshot(c, "\(tag)-notification-reply-button", wait: 0.6)
        m.startReply(sam)
        pump(0.3)
        check(c.panel.acceptsKeyboard, "\(tag): replying gives the island the keyboard")
        snapshot(c, "\(tag)-notification-replying", wait: 0.8)
        m.dismissToast()
        pump(0.2)
        check(!c.panel.acceptsKeyboard, "\(tag): closing the reply gives the keyboard back")
        pump(0.6)
        check(m.state == .closed, "\(tag): dismissing closes it")

        // Claude finished a long task
        m.showFinished(ClaudeFinish(project: "Notch+", branch: "main", duration: 134, message: "I added the new notification cards and all 120 checks pass.", terminal: TerminalRef(program: "Apple_Terminal", tty: "ttys000")), seconds: 5)
        check(m.state == .finished, "\(tag): Claude finishing shows a card")
        snapshot(c, "\(tag)-finished")
        m.dismissFinished()
        pump(0.5)
        c.panel.orderOut(nil)
    }

    // MARK: 6. Notifications from other apps (made-up database, never your real one)
    print("6. Notifications")
    // the Full Disk Access card finds System Settings through the window list (top-left origin) and must
    // convert to AppKit's bottom-left origin to sit under its window
    let mainH = NSScreen.screens.first?.frame.height ?? 0
    check(AccessGuide.appKitFrame(CGRect(x: 100, y: 50, width: 600, height: 400)) == CGRect(x: 100, y: mainH - 450, width: 600, height: 400),
          "access card: window list coordinates are flipped to the screen's")
    let suite = UserDefaults(suiteName: "notchplus.tests")!
    suite.removePersistentDomain(forName: "notchplus.tests")
    let rules = NotificationRules(defaults: suite)
    let nm = NotchModel(rules: rules)
    let dbPath = base.appendingPathComponent("fixture.db").path
    var fdb: OpaquePointer?
    sqlite3_open(dbPath, &fdb)
    sqlite3_exec(fdb, "CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT); CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB, delivered_date REAL);", nil, nil, nil)
    sqlite3_exec(fdb, "INSERT INTO app VALUES (1,'com.apple.MobileSMS'),(2,'com.example.noisy'),(3,'com.example.chatty'),(4,'com.example.legacy'),(5,'com.nurik.NotchPlus');", nil, nil, nil)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    func insertRow(_ id: Int, app: Int, blob: Data) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(fdb, "INSERT INTO record VALUES (?,?,?,?)", -1, &st, nil)
        sqlite3_bind_int(st, 1, Int32(id)); sqlite3_bind_int(st, 2, Int32(app))
        blob.withUnsafeBytes { _ = sqlite3_bind_blob(st, 3, $0.baseAddress, Int32(blob.count), transient) }
        sqlite3_bind_double(st, 4, Date().timeIntervalSinceReferenceDate)
        sqlite3_step(st); sqlite3_finalize(st)
    }
    func plist(_ d: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0) }
    insertRow(1, app: 1, blob: plist(["req": ["titl": "Old one", "body": "was here before Notch+ started"]]))
    insertRow(2, app: 2, blob: plist(["req": ["titl": "Old two", "body": "also before"]]))

    check(NotificationReader.databasePath(home: home) == nil, "no database found on a home without one")
    let nc = NotificationController(model: nm, databasePath: dbPath)
    nc.start()
    check(nm.notificationAccess == .granted, "database readable: reading starts")
    pump(0.5)
    check(nm.notifications.isEmpty && nm.toast == nil, "notifications from before start are not replayed")

    insertRow(3, app: 1, blob: plist(["req": ["titl": "Mum", "subt": "Messages", "body": "Dinner at 7?"]]))
    check(waitUntil(4) { nm.toast != nil }, "a new notification arrives within a few seconds")
    check(nm.toast?.headline == "Mum" && nm.toast?.detail == "Messages - Dinner at 7?", "title, subtitle and body are read")
    check(nm.toast?.bundleID == "com.apple.MobileSMS" && nm.state == .notification, "app is identified and the island opens")
    check(rules.seenApps["com.apple.MobileSMS"] != nil, "the app is remembered for the settings list")

    nm.dismissToast()
    rules.set(.ignore, for: "com.example.noisy")
    insertRow(4, app: 2, blob: plist(["req": ["titl": "Buy now", "body": "50% off"]]))
    check(waitUntil(4) { rules.seenApps["com.example.noisy"] != nil }, "ignored app is still remembered")
    pump(0.3)
    check(nm.toast == nil && !nm.notifications.contains { $0.bundleID == "com.example.noisy" }, "ignored app: nothing shown, nothing kept")

    rules.set(.quiet, for: "com.example.chatty")
    insertRow(5, app: 3, blob: plist(["req": ["titl": "Group chat", "body": "lol"]]))
    check(waitUntil(4) { nm.notifications.contains { $0.bundleID == "com.example.chatty" } }, "quiet app: kept in the recent list")
    check(nm.toast == nil, "quiet app: the island does not open")

    nm.dismissToast()
    insertRow(6, app: 4, blob: plist(["titl": "Old format", "body": "text at the top level"]))
    check(waitUntil(4) { nm.toast?.headline == "Old format" }, "older macOS layout (no req) is read too")

    nm.dismissToast()
    insertRow(7, app: 4, blob: Data("this is not a plist".utf8))
    insertRow(8, app: 5, blob: plist(["req": ["titl": "Notch+ itself", "body": "should never loop"]]))
    insertRow(9, app: 1, blob: plist(["req": ["titl": "After the bad one", "body": "still works"]]))
    check(waitUntil(4) { nm.toast?.headline == "After the bad one" }, "a broken row is skipped and reading continues")
    check(!nm.notifications.contains { $0.bundleID == "com.nurik.NotchPlus" }, "Notch+'s own notifications are never shown")

    // Messages re-delivers by updating its existing record (same rec_id, newer delivered_date), seen on macOS 27
    while nm.toast != nil { nm.dismissToast() }
    let redelivered = plist(["req": ["titl": "Mum", "body": "Are you coming?", "thre": "any;-;mum@example.com"]])
    var up: OpaquePointer?
    sqlite3_prepare_v2(fdb, "UPDATE record SET data = ?, delivered_date = ? WHERE rec_id = 3", -1, &up, nil)
    redelivered.withUnsafeBytes { _ = sqlite3_bind_blob(up, 1, $0.baseAddress, Int32(redelivered.count), transient) }
    sqlite3_bind_double(up, 2, Date().timeIntervalSinceReferenceDate + 1)
    sqlite3_step(up); sqlite3_finalize(up)
    check(waitUntil(4) { nm.toast?.detail == "Are you coming?" }, "a notification re-delivered into its old record still shows")
    check(NotificationRules(defaults: suite).mode(for: "com.example.noisy") == .ignore, "per-app choices are saved")
    check(nm.notifications.count <= 30, "recent list is capped")

    nc.stop()
    let locked = base.appendingPathComponent("locked.db")
    try! Data("x".utf8).write(to: locked)
    try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    let nm2 = NotchModel(rules: rules)
    let nc2 = NotificationController(model: nm2, databasePath: locked.path)
    nc2.start()
    check(nm2.notificationAccess == .needsFullDiskAccess, "unreadable database: asks for Full Disk Access")
    let nc3 = NotificationController(model: nm2, databasePath: nil)
    nc3.start()
    check(nm2.notificationAccess == .needsFullDiskAccess, "no database at all: asks for Full Disk Access")
    nc2.stop(); nc3.stop()
    // access that arrives after Notch+ opened (granted later, or after a rebuild) starts the watcher by itself
    var accessGranted = false
    let nm3 = NotchModel(rules: rules)
    let nc4 = NotificationController(model: nm3, databasePath: accessGranted ? dbPath : nil)
    nc4.start()
    check(nm3.notificationAccess == .needsFullDiskAccess, "late access: waits while there is none")
    accessGranted = true
    pump(4)
    check(nm3.notificationAccess == .granted, "late access: starts by itself once it can read, no reopening needed")
    nc4.stop()
    sqlite3_close(fdb)


    // MARK: 7. Live status, Apple Intelligence, Focus, shortcuts
    print("7. Live status and intelligence")
    let lm = NotchModel(rules: NotificationRules(defaults: suite), defaults: UserDefaults(suiteName: "notchplus.tests.live")!)
    lm.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/tmp/proj"])
    check(lm.liveSession?.status == .working && lm.state == .wings, "prompt submitted: session is working, live beside the notch")
    lm.handleEvent(["hook_event_name": "PreToolUse", "session_id": "a", "cwd": "/tmp/proj", "tool_name": "Edit"])
    check(lm.liveSession?.tool == "Edit", "tool in use is tracked")
    lm.handleEvent(["hook_event_name": "PostToolUse", "session_id": "a", "cwd": "/tmp/proj"])
    check(lm.liveSession?.tool == nil, "after the tool: thinking again")
    lm.sessions["a"]?.turnStart = Date().addingTimeInterval(-3)
    lm.handleEvent(["hook_event_name": "Stop", "session_id": "a", "cwd": "/tmp/proj", "last_assistant_message": "Done. Everything works."])
    check(lm.sessions["a"]?.status == .done && lm.liveSession == nil, "stop: session done, no longer live")
    check(lm.finished == nil && lm.finishedLog.count == 1, "a quick task is logged but gets no card")
    check(lm.finishedLog.first?.message == "Done.", "first sentence of Claude's last message is kept")
    lm.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/tmp/proj"])
    lm.sessions["a"]?.turnStart = Date().addingTimeInterval(-95)
    lm.handleEvent(["hook_event_name": "Stop", "session_id": "a", "cwd": "/tmp/proj"])
    check(lm.finished != nil && lm.state == .finished, "a long task (95 s) gets a finished card")
    check((lm.finished?.duration ?? 0) > 90, "its duration is measured")
    lm.dismissFinished()
    lm.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "b", "cwd": "/tmp/other"])
    lm.sessions["b"]?.lastEvent = Date().addingTimeInterval(-300)
    check(lm.liveSession == nil, "a working session silent for minutes is treated as stopped (Esc sends no event)")
    lm.handleEvent(["hook_event_name": "SessionEnd", "session_id": "b"])
    check(lm.sessions["b"] == nil, "session end removes it")
    lm.handleEvent(["hook_event_name": "Notification", "session_id": "c", "cwd": "/tmp/c", "notification_type": "permission_prompt"])
    check(lm.sessions["c"]?.status == .waiting, "Claude asking for permission marks the session as waiting")
    lm.handleEvent(["hook_event_name": "SomethingNew", "session_id": "c"])
    check(true, "unknown events are ignored without trouble")
    check(NotchModel.firstSentence("Hello there. More text.") == "Hello there.", "first sentence cut")
    check(NotchModel.firstSentence("   ") == nil && NotchModel.firstSentence(nil) == nil, "empty message gives nothing")
    check(Elapsed.clock(42) == "0:42" && Elapsed.clock(754) == "12:34" && Elapsed.clock(4000) == "1:06:40", "clock format")
    let nowD = Date()
    check(Elapsed.ago(nowD, now: nowD) == "now" && Elapsed.ago(nowD.addingTimeInterval(-40), now: nowD) == "40s" && Elapsed.ago(nowD.addingTimeInterval(-600), now: nowD) == "10m" && Elapsed.ago(nowD.addingTimeInterval(-7300), now: nowD) == "2h", "short 'how long ago' format")
    check(Elapsed.words(42) == "42 s" && Elapsed.words(134) == "2 min 14 s" && Elapsed.words(3900) == "1 h 5 min", "words format")

    let gitDir = base.appendingPathComponent("repo/.git"); try! FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    try! "ref: refs/heads/feature/notch\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    let sub = base.appendingPathComponent("repo/Sources/App"); try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    check(GitBranch.read(from: sub.path) == "feature/notch", "git branch found from a folder inside the repo")
    check(GitBranch.read(from: "/nonexistent/place") == nil, "no repo: no branch")

    // sessions list and jumping back to the terminal (environment recorded from a real hook on 2026-10-13)
    let sl = NotchModel(rules: NotificationRules(defaults: suite), defaults: UserDefaults(suiteName: "notchplus.tests.sessions")!)
    let term: [String: String] = ["program": "Apple_Terminal", "tab": "A0281CF4-7D5B-4D85-B9C3-0E25F95AB56F", "iterm": "", "tty": "ttys000"]
    sl.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "x", "cwd": "/tmp/proj/Sources/App",
                    "_notch_project_dir": "/tmp/proj", TerminalRef.key: term])
    check(sl.sessions["x"]?.project == "proj", "sessions: the project is Claude's own folder, not the subfolder it is in")
    check(sl.sessions["x"]?.terminal == TerminalRef(program: "Apple_Terminal", tab: "A0281CF4-7D5B-4D85-B9C3-0E25F95AB56F", tty: "ttys000"),
          "sessions: the terminal it runs in is remembered")
    sl.handleEvent(["hook_event_name": "Stop", "session_id": "x", "_notch_project_dir": "/tmp/proj",
                    "last_assistant_message": "All **tests** pass.\nI also updated `README.md`."])
    check(sl.sessions["x"]?.lastReply == "All tests pass. I also updated README.md.", "sessions: Claude's last answer is kept on one clean line")
    sl.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "y", "cwd": "/tmp/two"])
    sl.handleEvent(["hook_event_name": "Notification", "session_id": "z", "cwd": "/tmp/three", "notification_type": "permission_prompt"])
    sl.sessions["x"]?.turnStart = Date().addingTimeInterval(-60)
    sl.sessions["x"]?.status = .working
    sl.handleEvent(["hook_event_name": "Stop", "session_id": "x", "_notch_project_dir": "/tmp/proj", "last_assistant_message": "Done."])
    check(sl.finished?.terminal?.tty == "ttys000", "finished card: knows Claude's terminal, for Go to terminal")
    let tScript = TerminalJump.script(for: TerminalRef(program: "Apple_Terminal", tty: "ttys004")) ?? ""
    check(tScript.contains("tty of t is \"/dev/ttys004\"") && tScript.contains("set selected of t to true"), "jump: Terminal picks the tab by its tty")
    let iScript = TerminalJump.script(for: TerminalRef(program: "iTerm.app", iterm: "w0t1p0:ABC-123")) ?? ""
    check(iScript.contains("unique id of s is \"ABC-123\""), "jump: iTerm2 picks the session by its id")
    check(TerminalJump.script(for: TerminalRef(program: "vscode")) == nil && TerminalRef(program: "vscode").bundleID == "com.microsoft.VSCode",
          "jump: other apps are brought forward")
    check(HookInstaller(paths: paths).scriptText.contains("X-Notch-Terminal: ${TERM_PROGRAM:-}|${TERM_SESSION_ID:-}|${ITERM_SESSION_ID:-}|${TTY}|${CLAUDE_PROJECT_DIR:-}"),
          "hook script: sends the terminal and the project folder")

    // events through the real server
    print("   server events")
    let es = NotchModel(rules: NotificationRules(defaults: suite), defaults: UserDefaults(suiteName: "notchplus.tests.events")!)
    let eserver = HookServer(token: token)
    eserver.onRequest = { json, conn in es.handle(json: json, connection: conn) }
    eserver.onEvent = { json in es.handleEvent(json) }
    try! eserver.start()
    pump(0.3)
    let eurl = "http://127.0.0.1:\(NotchConfig.port)/event"
    let evJSON = #"{"hook_event_name":"UserPromptSubmit","session_id":"srv","cwd":"/tmp/served"}"#
    var er = run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", "--data-binary", evJSON, eurl])
    check(er.out == "401", "event without the token is refused")
    check(es.sessions["srv"] == nil, "refused event changes nothing")
    er = run("/usr/bin/curl", ["-s", "-H", "Authorization: Bearer \(token)", "-X", "POST", "--data-binary", evJSON, eurl])
    check(er.out == "{}", "event with the token is answered at once with {}")
    check(waitUntil { es.sessions["srv"]?.status == .working }, "event reaches the model")
    let hookEvent = run("/bin/sh", ["-c", installer.command(kind: "event")], stdin: #"{"hook_event_name":"PreToolUse","session_id":"srv","tool_name":"Grep","cwd":"/tmp/served"}"#)
    check(hookEvent.out == "{}" && hookEvent.status == 0, "the hook script sends events and returns at once")
    check(waitUntil { es.sessions["srv"]?.tool == "Grep" }, "event from the real script arrives")
    eserver.stop()
    pump(0.3)

    // installer events
    print("   installer events")
    let inst2 = HookInstaller(paths: paths)
    try! JSONSerialization.data(withJSONObject: ["model": "opus"]).write(to: paths.claudeSettings)
    _ = try! inst2.connect()
    let all = try! JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
    let hooksDict = all["hooks"] as! [String: Any]
    check(HookInstaller.events.allSatisfy { hooksDict[$0.name] != nil }, "all \(HookInstaller.events.count) events are registered")
    check(inst2.status() == .connected, "all events present: connected")
    var trimmed = all
    var h2 = hooksDict; h2.removeValue(forKey: "PreToolUse"); trimmed["hooks"] = h2
    try! JSONSerialization.data(withJSONObject: trimmed).write(to: paths.claudeSettings)
    check(inst2.status() == .outdated, "some events missing: shown as needing an update")
    _ = try! inst2.connect()
    check(inst2.status() == .connected, "connecting again repairs it")
    // an entry from the first Notch+ build (plain, unquoted path) is recognised and replaced
    let legacy: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": paths.hookScript.path, "timeout": 590]]]]]]
    try! JSONSerialization.data(withJSONObject: legacy).write(to: paths.claudeSettings)
    check(inst2.status() == .outdated, "first-build entry counts as connected but outdated")
    _ = try! inst2.connect()
    let afterLegacy = try! JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
    check((((afterLegacy["hooks"] as! [String: Any])["PermissionRequest"]) as! [Any]).count == 1, "old entry replaced, not duplicated")
    _ = try! inst2.disconnect()
    let cleaned = try! JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
    check(cleaned["hooks"] == nil, "disconnect removes every Notch+ entry")

    // notifications: triage, Focus, mute
    print("   triage, focus, mute")
    let tdef = UserDefaults(suiteName: "notchplus.tests.triage")!
    tdef.removePersistentDomain(forName: "notchplus.tests.triage")
    let trules = NotificationRules(defaults: tdef)
    let tm = NotchModel(rules: trules, defaults: tdef)
    func raw(_ id: Int, _ app: String, _ title: String, _ body: String) -> RawNotification {
        RawNotification(recordID: Int64(id), bundleID: app, title: title, subtitle: nil, body: body, date: Date())
    }
    tm.triage = { r in r.title == "Spam" ? TriageResult(priority: .noise, summary: "A promotion.") : TriageResult(priority: .now, summary: "Needs an answer by five.") }
    tm.receive([raw(1, "com.example.a", "Spam", "50% off today")])
    check(tm.toast != nil && tm.notifications.count == 1, "every notification shows at once, before Apple Intelligence answers")
    check(waitUntil { tm.notifications.first?.priority == .noise } && tm.toast != nil, "noise is only labelled, never hidden")
    tm.dismissToast()
    tm.receive([raw(2, "com.example.a", "Mum", "Dinner?")])
    check(tm.toast != nil, "important one: the island opens")
    check(waitUntil { tm.toast?.priority == .now } && tm.toast?.summary == nil, "by default the label is added but the full message stays (no summary)")
    tm.dismissToast()
    tm.notificationText = .summary
    tm.receive([raw(4, "com.example.a", "Mum", "Dinner tonight at seven at our place, can you bring the salad and pick up bread on the way? Let me know before five please.")])
    check(waitUntil { tm.toast?.summary == "Needs an answer by five." }, "with Short summary chosen, the summary is added to the open card")
    tm.sortWithAppleIntelligence = false
    tm.dismissToast()
    tm.receive([raw(5, "com.example.a", "Mum", "Dinner tonight at seven at our place, can you bring the salad and pick up bread on the way? Let me know before five please.")])
    check(waitUntil { tm.toast?.summary != nil } && tm.toast?.priority == nil, "summary without labels when only the summary is chosen")
    tm.dismissToast()
    tm.receive([raw(8, "com.example.a", "Mum", "You good?")])
    pump(0.4)
    check(tm.toast?.summary == nil, "summary: a short message stays word for word (no summary asked for)")
    tm.sortWithAppleIntelligence = true
    tm.notificationText = .full
    // two at the same moment: both are shown, one after the other
    tm.dismissToast()
    tm.receive([raw(6, "com.apple.mobilesms", "Sam", "Hi"), raw(7, "ru.keepcoder.telegram", "Alex", "Yo")])
    check(tm.toast?.headline == "Sam" && tm.toastsWaiting == 1, "two at once: the first shows, the second waits (+1)")
    tm.dismissToast()
    check(tm.toast?.headline == "Alex" && tm.toastsWaiting == 0, "two at once: the second shows when the first closes")
    tm.dismissToast()

    // the Recent list: quiet notifications are counted until it is opened
    tm.dismissToast()
    tm.quietUnseen = 0
    trules.set(.quiet, for: "com.example.quiet")
    tm.receive([raw(30, "com.example.quiet", "Newsletter", "This week in Swift"), raw(31, "com.example.quiet", "Newsletter", "Part two")])
    check(tm.toast == nil && tm.quietUnseen == 2, "recent: quiet notifications open no card but are counted")
    check(tm.notifications.first?.headline == "Newsletter", "recent: they are in the list")
    tm.openRecent()
    check(tm.homeTab == .recent && tm.quietUnseen == 0, "recent: opening the list shows it and clears the count")
    tm.clearRecent()
    check(tm.notifications.isEmpty && tm.homeTab != .recent, "recent: Clear empties it and the tab gives way")

    // replying to Messages from the card
    func msg(_ id: Int, thread: String?, app: String = "com.apple.mobilesms") -> RawNotification {
        RawNotification(recordID: Int64(id), bundleID: app, title: "Sam", subtitle: nil, body: "Drinks at 9?", date: Date(), thread: thread)
    }
    check(MessagesReply.handle(for: msg(20, thread: "any;-;sam@example.com")) == "sam@example.com", "reply: the handle is read from the thread id (any;-;<handle>)")
    check(MessagesReply.handle(for: msg(21, thread: "any;-;+15551234567")) == "+15551234567", "reply: phone numbers work too")
    check(MessagesReply.handle(for: msg(22, thread: "any;+;chat12345")) == nil, "reply: group chats are not offered")
    check(MessagesReply.handle(for: msg(23, thread: nil)) == nil && MessagesReply.handle(for: msg(24, thread: "any;-;x", app: "ru.keepcoder.telegram")) == nil,
          "reply: only Messages, and only with a thread id")
    let replyScript = MessagesReply.script(text: "say \"hi\" \\ ok", to: "sam@example.com")
    check(replyScript.contains("send \"say \\\"hi\\\" \\\\ ok\" to participant \"sam@example.com\""), "reply: quotes and backslashes in the text are escaped")
    var replySent: [(String, String)] = []
    tm.sendMessage = { t, h in replySent.append((t, h)) }
    tm.suggestReplies = { _, _ in ["Yes!", "Can't tonight", "Where?"] }
    tm.receive([msg(25, thread: "any;-;sam@example.com")])
    check(tm.toast != nil && tm.canReply(tm.toast!), "reply: a Messages card offers Reply")
    tm.startReply(tm.toast!)
    check(waitUntil { tm.replySuggestions.count == 3 } && tm.replying == tm.toast?.id, "reply: three suggestions arrive, nothing is sent")
    check(replySent.isEmpty, "reply: suggestions are never sent by themselves")
    pump(6.5)
    check(tm.toast != nil, "reply: the card stays open while you type (no 6 second close)")
    tm.sendReply("   ")
    check(replySent.isEmpty, "reply: an empty reply is not sent")
    tm.sendReply("Yes! See you there")
    check(waitUntil { tm.toast == nil } && replySent.count == 1 && replySent[0].0 == "Yes! See you there" && replySent[0].1 == "sam@example.com",
          "reply: Send sends once, to the right person, and the card closes")
    check(tm.flash?.text == "Sent", "reply: a short Sent shows beside the notch")
    tm.sendMessage = { _, _ in throw MessagesReply.SendError.notAllowed }
    tm.receive([msg(26, thread: "any;-;sam@example.com")])
    tm.startReply(tm.toast!)
    tm.sendReply("ok")
    check(waitUntil { tm.replyError != nil } && tm.toast != nil && tm.replyError!.contains("Automation"),
          "reply: if Messages refuses, the card stays and says how to allow it")
    tm.messagesReplyOn = false
    check(!tm.canReply(tm.toast!), "reply: switched off in Settings, no Reply button")
    tm.messagesReplyOn = true
    tm.dismissToast()
    check(tm.replying == nil, "reply: closing the card ends the reply")

    // Claude's own questions, with the payload recorded from a real Claude Code session (2026-10-13)
    let askJSON = #"{"session_id":"q1","cwd":"/Users/nurik/Desktop/Notch+","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should we use?","header":"Database","options":[{"label":"SQLite (Recommended)","description":"Simple, one file."},{"label":"Postgres","description":"A server."}],"multiSelect":false},{"question":"Which extras?","header":"Extras","options":[{"label":"Tests","description":""},{"label":"Docs","description":""},{"label":"CI","description":""}],"multiSelect":true}]}}"#
    let askObj = try! JSONSerialization.jsonObject(with: Data(askJSON.utf8)) as! [String: Any]
    let qConn = HookConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    tm.handle(json: askObj, connection: qConn)
    let qr = tm.current?.request
    check(qr?.isQuestion == true && qr?.questions.count == 2 && qr?.questions[0].options.count == 2 && qr?.questions[1].multiSelect == true,
          "question: Claude's question arrives as a question, not as a tool approval")
    check(qr?.questions[0].options[0].isRecommended == true && qr?.questions[0].options[0].title == "SQLite", "question: the recommended option is marked and shown without the marker")
    check(tm.state == .approval, "question: the island opens for it")
    tm.answer(allow: true)
    check(tm.current?.request.isQuestion == true && qConn.sentBody == nil, "question: Send does nothing until every question has a pick")
    tm.pick(qr!.questions[0].options[1], in: qr!.questions[0])
    tm.pick(qr!.questions[0].options[0], in: qr!.questions[0])
    check(tm.questionPicks["Which database should we use?"] == ["SQLite (Recommended)"], "question: one choice replaces the other")
    tm.pick(qr!.questions[1].options[2], in: qr!.questions[1])
    tm.pick(qr!.questions[1].options[0], in: qr!.questions[1])
    tm.pick(qr!.questions[1].options[2], in: qr!.questions[1])
    tm.pick(qr!.questions[1].options[2], in: qr!.questions[1])
    check(Set(tm.questionPicks["Which extras?"] ?? []) == ["Tests", "CI"], "question: several picks toggle on and off")
    check(tm.questionsAnswered, "question: ready to send")
    tm.answerQuestions()
    let qBody = (try? JSONSerialization.jsonObject(with: Data((qConn.sentBody ?? "").utf8))) as? [String: Any]
    let qDecision = (qBody?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    let qUpdated = qDecision?["updatedInput"] as? [String: Any]
    let qAnswers = qUpdated?["answers"] as? [String: String]
    check(qDecision?["behavior"] as? String == "allow" && (qUpdated?["questions"] as? [[String: Any]])?.count == 2,
          "question: the answer allows the tool and echoes the questions")
    check(qAnswers?["Which database should we use?"] == "SQLite (Recommended)" && qAnswers?["Which extras?"] == "Tests, CI",
          "question: answers are keyed by question text with the exact labels, several joined in Claude's order")
    check(qUpdated?["annotations"] is [String: Any], "question: annotations are included, as Claude Code itself sends them")
    check(tm.pending.isEmpty && tm.questionPicks.isEmpty, "question: answered and cleared")
    let qConn2 = HookConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    tm.handle(json: askObj, connection: qConn2)
    tm.answer(allow: false)
    check(qConn2.sentBody == "{}" && tm.pending.isEmpty, "question: In terminal hands it back (an empty answer, so Claude Code asks there)")
    check(trules.mode(for: "COM.EXAMPLE.A") == .show && NotificationRules.isOwn("com.nurik.notchplus"), "app ids match ignoring case (the database stores them in lower case)")
    trules.set(.quiet, for: "com.Example.B")
    check(trules.mode(for: "com.example.b") == .quiet, "a choice made for one spelling holds for the other")
    tm.dismissToast()
    tm.sortWithAppleIntelligence = false
    tm.receive([raw(3, "com.example.a", "Spam", "again")])
    check(tm.toast != nil, "with sorting switched off every notification shows")
    tm.dismissToast()
    tm.sortWithAppleIntelligence = true
    tm.focusIsOn = { true }
    tm.receive([raw(4, "com.example.a", "Mum", "Are you there?")])
    check(waitUntil { tm.notifications.contains { $0.headline == "Mum" && $0.raw.body == "Are you there?" } }, "during Focus the notification is kept")
    check(tm.toast == nil, "during Focus the island stays quiet")
    tm.respectFocus = false
    tm.receive([raw(5, "com.example.a", "Mum", "Urgent")])
    check(waitUntil { tm.toast != nil }, "with 'respect Focus' off it shows anyway")
    if let t = tm.toast { tm.muteSource(of: t) }
    check(trules.mode(for: "com.example.a") == .quiet && tm.toast == nil, "mute: the app is set to quiet and the card closes")

    let focusHome = base.appendingPathComponent("focushome/Library/DoNotDisturb/DB"); try! FileManager.default.createDirectory(at: focusHome, withIntermediateDirectories: true)
    let fhome = base.appendingPathComponent("focushome")
    try! #"{"data":[{"storeAssertionRecords":[{"assertionUUID":"x"}],"storeInvalidationRecords":[]}]}"#.write(to: focusHome.appendingPathComponent("Assertions.json"), atomically: true, encoding: .utf8)
    check(FocusState.isOn(home: fhome), "Focus on is detected")
    try! #"{"data":[{"storeAssertionRecords":[],"storeInvalidationRecords":[{"x":1}]}]}"#.write(to: focusHome.appendingPathComponent("Assertions.json"), atomically: true, encoding: .utf8)
    check(!FocusState.isOn(home: fhome), "Focus off is detected")
    check(!FocusState.isOn(home: base.appendingPathComponent("nohome")), "no Focus file: not on")

    // keyboard shortcuts
    let keys = HotKeys.shared
    check(keys.enable(), "the three keyboard shortcuts register")
    keys.disable()
    check(!keys.isEnabled, "and are released again")

    // Apple Intelligence on this Mac
    print("   Apple Intelligence (this Mac)")
    if Intelligence.isAvailable {
        var explained: String?
        var done = false
        Task { explained = await Intelligence.explain(tool: "Bash", headline: "Run a risky command", detail: "rm -rf node_modules"); done = true }
        _ = waitUntil(9) { done }
        check(explained?.isEmpty == false, "the on-device model explains a command in plain words")
        print("         -> \(explained ?? "nothing")")
        var tri: TriageResult?
        var done2 = false
        Task { tri = await Intelligence.triage(raw(9, "com.bank.app", "Bank", "A payment of 480.00 was declined, please check your card"), appName: "Bank"); done2 = true }
        _ = waitUntil(9) { done2 }
        check(tri != nil && tri?.priority != .noise, "a declined payment is never sorted out as noise")
        print("         -> \(tri.map { "\($0.priority) | \($0.summary)" } ?? "nothing")")
        var tri2: TriageResult?
        var done3 = false
        Task { tri2 = await Intelligence.triage(raw(10, "com.social.app", "Instagram", "14 people liked your photo"), appName: "Instagram"); done3 = true }
        _ = waitUntil(9) { done3 }
        check(tri2?.priority == .noise, "likes are sorted out as noise")
        print("         -> \(tri2.map { "\($0.priority) | \($0.summary)" } ?? "nothing")")
    } else {
        print("         Apple Intelligence is not available here: skipped")
    }


    // MARK: 8. Motion: does the island really grow and shrink smoothly?
    print("8. Motion")
    /// Width in points of the black shape, read from the pixels near the top edge.
    func shapeWidth(_ c: NotchWindowController) -> CGFloat {
        guard let v = c.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return 0 }
        v.cacheDisplay(in: v.bounds, to: rep)
        let y = 8
        var left = -1, right = -1
        for x in 0..<rep.pixelsWide {
            if let col = rep.colorAt(x: x, y: y), col.alphaComponent > 0.5 { if left < 0 { left = x }; right = x }
        }
        return left < 0 ? 0 : CGFloat(right - left + 1) / CGFloat(rep.pixelsWide / Int(v.bounds.width))
    }
    func shapeHeight(_ c: NotchWindowController) -> CGFloat {
        guard let v = c.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return 0 }
        v.cacheDisplay(in: v.bounds, to: rep)
        let x = rep.pixelsWide / 2
        var bottom = 0
        for y in 0..<rep.pixelsHigh { if let col = rep.colorAt(x: x, y: y), col.alphaComponent > 0.5 { bottom = y } }
        return CGFloat(bottom + 1) / CGFloat(rep.pixelsHigh / Int(v.bounds.height))
    }
    do {
        let g = NotchGeometry.fake(notch: true)
        let mm = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.motion")!), defaults: UserDefaults(suiteName: "notchplus.tests.motion")!)
        mm.hookStatus = .connected
        let mc = NotchWindowController(model: mm, geometry: g, liveMouse: false, openSettings: {})
        pump(0.5)
        let closedW = shapeWidth(mc)
        mm.hovering = true
        var samples: [(Double, CGFloat)] = []
        var t = 0.0
        for step in [0.01, 0.01, 0.02, 0.02, 0.02, 0.03, 0.03, 0.04, 0.05, 0.08, 0.15, 0.3, 0.5] {
            pump(step); t += step
            samples.append((t, shapeWidth(mc)))
        }
        pump(0.8)
        let finalW = shapeWidth(mc)
        print("      closed \(Int(closedW)) pt; opening: " + samples.map { String(format: "%.2fs=%d", $0.0, Int($0.1)) }.joined(separator: " ") + "; final \(Int(finalW))")
        check(abs(closedW - g.notchSize.width) < 16, "motion: starts at the notch width")
        check(finalW > closedW + 150, "motion: ends clearly wider")
        let mid = samples.filter { $0.1 > closedW + 10 && $0.1 < finalW - 10 }
        check(mid.count >= 2, "motion: passes through in-between widths (it animates, it does not jump)")
        let widths = samples.map(\.1)
        check(zip(widths, widths.dropFirst()).filter { $1 + 1 < $0 }.count <= 2, "motion: grows steadily")
        mm.hovering = false
        var shrink: [CGFloat] = []
        for step in [0.05, 0.1, 0.15, 0.3] { pump(step); shrink.append(shapeWidth(mc)) }
        print("      closing: " + shrink.map { "\(Int($0))" }.joined(separator: " "))
        check(shrink.contains { $0 > closedW + 10 && $0 < finalW - 10 }, "motion: closing also passes through in-between widths")
        pump(0.8)

        // the pointer leaning in before the island opens
        mm.anticipating = true
        pump(0.7)
        let leanW = shapeWidth(mc)
        check(leanW > closedW + 8, "motion: the island leans toward the pointer before opening (\(Int(closedW)) -> \(Int(leanW)) pt)")
        mm.anticipating = false
        pump(0.7)

        // size follows content
        mm.hovering = true
        pump(0.8)
        let ovH = mm.contentHeights[.overview] ?? 0
        check(ovH > 120 && ovH < 260, "size: the overview measured itself (\(Int(ovH)) pt) and is compact")
        check(abs(shapeHeight(mc) - ovH) < 3, "size: the drawn island is exactly as tall as its content (\(Int(shapeHeight(mc))) pt)")
        mm.hovering = false
        pump(0.6)
        let dummyC = HookConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
        mm.handle(json: ["tool_name": "Bash", "session_id": "m", "tool_input": ["command": "ls"], "cwd": "/tmp"], connection: dummyC)
        pump(0.9)
        let shortH = mm.contentHeights[.approval] ?? 0
        let shortShape = shapeHeight(mc)
        mm.pending.removeAll()
        pump(0.6)
        mm.handle(json: ["tool_name": "Bash", "session_id": "m", "tool_input": ["command": String(repeating: "git commit -m \"a fairly long message\" && ", count: 6) + "git push"], "cwd": "/tmp"], connection: dummyC)
        pump(0.9)
        let longH = mm.contentHeights[.approval] ?? 0
        check(shortH > 120 && shortH < 230, "size: a short request is compact (\(Int(shortH)) pt)")
        check(longH > shortH + 12, "size: a long command makes the island taller (\(Int(shortH)) -> \(Int(longH)) pt)")
        check(abs(shortShape - shortH) < 3, "size: the island hugs a short request (\(Int(shortShape)) vs \(Int(shortH)) pt)")
        mm.pending.removeAll()
        pump(0.6)
        mc.panel.orderOut(nil)
    }


    // MARK: 9. Home: player and shelf
    print("9. Player and shelf")
    // a tiny cover image for tests
    func coverPNG() -> Data {
        let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            NSGradient(colors: [NSColor.systemPink, NSColor.systemOrange])?.draw(in: r, angle: 45)
            return true
        }
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
    let cover64 = coverPNG().base64EncodedString()
    let playingLine = #"{"type":"data","diff":false,"payload":{"title":"Night Drive","artist":"Aria","album":"Neon","duration":200.0,"elapsedTime":50.0,"playbackRate":1,"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","playing":true,"timestamp":"2026-10-10T01:39:40Z","artworkData":"\#(cover64)"}}"#
    if case .info(let ni) = NowPlayingParser.parse(line: Data(playingLine.utf8)) {
        check(ni.title == "Night Drive" && ni.artist == "Aria" && ni.album == "Neon", "player: title, artist and album are read")
        check(ni.bundleID == "com.apple.Safari" && ni.playing && ni.duration == 200, "player: the browser (not the helper process) is the source")
        check(ni.artwork != nil, "player: the cover is decoded")
        var paused = ni; paused.playing = false
        var running = ni; running.stamp = Date().addingTimeInterval(-10)
        check(abs(running.elapsedNow() - 60) < 1.5, "player: position moves on while it plays")
        check(paused.elapsedNow() == 50, "player: position stays put while paused")
        running.stamp = Date().addingTimeInterval(-500)
        check(running.elapsedNow() == 200, "player: position never runs past the end")
    } else { check(false, "player: a playing line is parsed") }
    let bare = #"{"title":"Direct","playbackRate":0,"bundleIdentifier":"com.spotify.client"}"#
    if case .info(let b) = NowPlayingParser.parse(line: Data(bare.utf8)) { check(b.title == "Direct" && !b.playing && b.bundleID == "com.spotify.client", "player: the plain 'get' layout is read too") } else { check(false, "player: plain layout") }
    check(NowPlayingParser.parse(line: Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8)) == .cleared, "player: an empty report means nothing is playing")
    check(NowPlayingParser.parse(line: Data("not json".utf8)) == .invalid, "player: garbage is ignored")

    // the real helper, read only (never sends a command: your media is not touched)
    let vendor = FileManager.default.currentDirectoryPath + "/Vendor"
    let live = NowPlayingController(script: URL(fileURLWithPath: vendor + "/mediaremote-adapter.pl"), framework: URL(fileURLWithPath: vendor + "/MediaRemoteAdapter.framework"))
    check(live.isAvailable, "player: the bundled helper is present")
    var heard = false
    var heardInfo: NowPlayingInfo?
    live.onChange = { i in heard = true; heardInfo = i }
    check(live.start(), "player: the helper starts")
    _ = waitUntil(8) { heard }
    print("         helper reported: \(heard ? (heardInfo.map { "\($0.playing ? "playing" : "paused") from \($0.bundleID)" } ?? "nothing playing") : "no report within 8 s (nothing is playing)")")
    live.stop()

    // the home view chooses by itself
    let hdef = UserDefaults(suiteName: "notchplus.tests.home")!; hdef.removePersistentDomain(forName: "notchplus.tests.home")
    let shelfDir = base.appendingPathComponent("shelf"); try? FileManager.default.removeItem(at: shelfDir)
    try! FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true)
    func makeFile(_ name: String, _ text: String = "hello") -> URL {
        let u = shelfDir.appendingPathComponent(name); try! text.write(to: u, atomically: true, encoding: .utf8); return u
    }
    let hm = NotchModel(rules: NotificationRules(defaults: hdef), defaults: hdef, shelf: ShelfStore(file: shelfDir.appendingPathComponent("shelf.json")))
    check(hm.homeTab == .shelf, "home: with nothing playing it is the shelf")
    guard case .info(var playingInfo) = NowPlayingParser.parse(line: Data(playingLine.utf8)) else { fatalError() }
    playingInfo.stamp = Date()
    hm.setNowPlaying(playingInfo)
    check(hm.homeTab == .player, "home: when something plays it is the player")
    hm.homeChoice = .shelf
    check(hm.homeTab == .shelf, "home: your own choice is respected")
    var paused2 = playingInfo; paused2.playing = false
    hm.homeChoice = .player
    hm.setNowPlaying(paused2)
    check(hm.homeChoice == .player, "home: pausing does not reset your tab")
    hm.homeChoice = nil
    check(hm.homeTab == .player, "home: pausing keeps the player open, so play can be pressed again")
    hm.setNowPlaying(nil)
    check(hm.homeChoice == nil && hm.homeTab == .shelf, "home: when the player goes away it goes back to automatic")
    hm.setNowPlaying(playingInfo)
    hm.dragging = true
    check(hm.homeTab == .shelf && hm.state == .overview, "home: a file drag opens the island on the shelf even over the player")
    hm.dragging = false
    check(hm.state == .wings && hm.musicWingsOn, "wings: music playing shows beside the notch")
    check(hm.wingsWidth < NotchGeometry.wingWidth, "wings: music is slimmer than Claude's")
    hm.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "q", "cwd": "/tmp"])
    check(hm.wingsWidth == NotchGeometry.wingWidth, "wings: Claude working takes over the space")
    check(hm.musicBubble, "wings: music still playing moves into the drop beside the island")
    hm.sessions = [:]
    check(!hm.musicBubble, "wings: with Claude done, the music comes back beside the notch")
    hm.showMusicBesideNotch = false
    check(hm.state == .closed, "wings: switched off in settings, the notch stays quiet")
    hm.showMusicBesideNotch = true
    hm.showHUD(HUDReading(kind: .volume, level: 0.5), seconds: 0.2)
    check(hm.state == .wings && hm.hud?.percent == 50 && hm.wingsWidth < NotchGeometry.wingWidth && hm.wingsWidth > 60, "hud: volume shows beside the notch, wings sized to the level bar")
    pump(0.5)
    check(hm.hud == nil, "hud: it goes away by itself")
    hm.showLevels = false
    hm.showHUD(HUDReading(kind: .brightness, level: 0.3))
    check(hm.hud == nil, "hud: switched off in settings, nothing shows")
    hm.showLevels = true
    check(HUDReading(kind: .volume, level: 0.8, muted: true).symbol == "speaker.slash.fill" && HUDReading(kind: .volume, level: 0.8, muted: true).percent == 0, "hud: muted shows the slashed speaker and 0")
    check(HUDReading(kind: .volume, level: 0.2).symbol == "speaker.wave.1.fill" && HUDReading(kind: .volume, level: 0.9).symbol == "speaker.wave.3.fill", "hud: speaker waves follow the level")
    var lw = LevelWatcher()
    check(!lw.feed(0.5, at: 0), "hud: first reading is not a change")
    check(!lw.feed(0.505, at: 0.15) && !lw.feed(0.51, at: 0.3) && !lw.feed(0.515, at: 0.45), "hud: slow automatic drift is ignored")
    check(lw.feed(0.58, at: 0.6), "hud: a key-sized step is a change")
    check(Marquee.fraction(at: 0, overflow: 0) == 0 && Marquee.fraction(at: 123, overflow: 0) == 0, "marquee: text that fits never moves")
    check(Marquee.fraction(at: 0.5, overflow: 100) == 0 && Marquee.fraction(at: 1.7, overflow: 100) == 0, "marquee: it waits at the start first")
    let mid = Marquee.fraction(at: 1.8 + 100.0 / 26 / 2, overflow: 100)
    check(abs(mid - 0.5) < 0.01, "marquee: halfway through the move it is halfway along (\(mid))")
    check(Marquee.fraction(at: 1.8 + 100.0 / 26 + 0.5, overflow: 100) == 1, "marquee: it rests at the end, then comes back")
    check(Marquee.fraction(at: 2 * (1.8 + 100.0 / 26) - 0.01, overflow: 100) < 0.05, "marquee: and is back at the start when the cycle ends")
    UserDefaults(suiteName: "notchplus.tests.glow")!.removePersistentDomain(forName: "notchplus.tests.glow")
    let gm = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.glow")!), defaults: UserDefaults(suiteName: "notchplus.tests.glow")!)
    check(gm.glowLevel == .normal && gm.glowLevel.factor == 1, "glow: normal by default")
    gm.glowLevel = .off
    check(gm.glowLevel == .off && gm.glowLevel.factor == 0, "glow: can be switched off")
    gm.glowLevel = .subtle
    check(NotchModel.GlowLevel.subtle.factor < 1 && NotchModel.GlowLevel.vivid.factor > 1 && gm.glowLevel == .subtle, "glow: subtle is softer and vivid stronger, and the choice is kept")
    // caffeine
    func held() -> Int { run("/usr/bin/pmset", ["-g", "assertions"]).out.components(separatedBy: "\n").filter { $0.contains("pid \(getpid())(") && $0.contains("Notch+ is keeping the Mac awake") }.count }
    let cm = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.caffeine")!), defaults: UserDefaults(suiteName: "notchplus.tests.caffeine")!)
    check(!cm.caffeine.active && held() == 0, "caffeine: starts off, nothing held")
    cm.setCaffeine(.untilOff)
    check(cm.caffeine.active && cm.caffeine.endsAt == nil && held() == 1, "caffeine: on holds the Mac awake (the system lists it)")
    check(cm.flash?.text == "Awake" && cm.state == .wings, "caffeine: a short 'Awake' beside the notch")
    cm.setCaffeine(nil)
    check(!cm.caffeine.active && held() == 0, "caffeine: off lets it sleep again")
    cm.caffeine.start(.minutes15, now: Date())
    check(cm.caffeine.active && (cm.caffeine.endsAt.map { abs($0.timeIntervalSinceNow - 900) < 2 } ?? false), "caffeine: a time limit sets the end")
    cm.caffeine.start(.hour1)
    check((cm.caffeine.endsAt.map { abs($0.timeIntervalSinceNow - 3600) < 2 } ?? false) && held() == 1, "caffeine: starting again replaces the old hold, never stacks")
    var expired = false
    cm.caffeine.onExpire = { expired = true }
    cm.caffeine.start(.minutes15, now: Date().addingTimeInterval(-899.8))
    _ = waitUntil(3) { expired }
    check(expired && !cm.caffeine.active && held() == 0, "caffeine: when the time runs out it lets go by itself")
    cm.caffeine.stop()
    cm.flash = nil

    var sw = SwipeTracker()
    check(sw.feed(dy: 5, began: true, ended: false) == nil && sw.feed(dy: 6, began: false, ended: false) == nil, "swipe: a small movement does nothing")
    check(sw.feed(dy: 6, began: false, ended: false) == .down, "swipe: fingers down opens")
    check(sw.feed(dy: 30, began: false, ended: false) == nil, "swipe: one swipe fires once")
    _ = sw.feed(dy: 0, began: false, ended: true)
    check(sw.feed(dy: -20, began: true, ended: false) == .up, "swipe: fingers up closes")
    let pw: (Bool, Int) -> PowerState = { PowerState(pluggedIn: $0, percent: $1) }
    check(PowerEvents.next(from: nil, to: pw(true, 80)) == nil, "power: the first reading is not an event")
    check(PowerEvents.next(from: pw(false, 80), to: pw(true, 80)) == .pluggedIn(80), "power: plugging in is an event")
    check(PowerEvents.next(from: pw(true, 100), to: pw(false, 100)) == .unplugged(100), "power: unplugging is an event")
    check(PowerEvents.next(from: pw(true, 50), to: pw(true, 51)) == nil && PowerEvents.next(from: pw(false, 60), to: pw(false, 59)) == nil, "power: ordinary percent changes are quiet")
    check(PowerEvents.next(from: pw(false, 21), to: pw(false, 20)) == .low(20) && PowerEvents.next(from: pw(false, 20), to: pw(false, 19)) == nil, "power: low battery speaks once when it crosses 20")
    check(PowerEvents.next(from: pw(false, 11), to: pw(false, 10)) == .critical(10), "power: critical at 10")
    check(PowerEvents.next(from: pw(true, 15), to: pw(true, 14)) == nil, "power: no low warning while charging")
    hm.showPower(.pluggedIn(73))
    check(hm.state == .wings && hm.flash?.symbol == "bolt.fill" && hm.flash?.text == "73%", "power: plugging in shows the bolt and the percentage")
    hm.showPower(.low(18))
    check(hm.flash?.good == false, "power: low battery is shown in red")
    hm.flash = nil
    var sent: [MediaCommand] = []; var sought: [Double] = []
    hm.mediaSend = { sent.append($0) }; hm.mediaSeek = { sought.append($0) }
    hm.sendMedia(.togglePlayPause); hm.sendMedia(.next); hm.seekMedia(to: 42)
    check(sent == [.togglePlayPause, .next] && sought == [42], "player: controls reach the player")
    check(MediaCommand.togglePlayPause.rawValue == 2 && MediaCommand.next.rawValue == 4 && MediaCommand.previous.rawValue == 5, "player: command numbers match the helper")

    // the shelf
    print("   shelf")
    let sh = hm.shelf
    let f1 = makeFile("report.txt"), f2 = makeFile("notes.md"), f3 = makeFile("budget.csv")
    check(sh.add([f1, f2]) == 2 && sh.items.count == 2, "shelf: files are added")
    check(sh.add([f1]) == 0 && sh.items.count == 2, "shelf: the same file twice is ignored")
    check(sh.add([URL(fileURLWithPath: "/nowhere/ghost.txt")]) == 0, "shelf: a file that does not exist is ignored")
    check(sh.items.first?.name == "notes.md", "shelf: newest first")
    check(ShelfStore(file: shelfDir.appendingPathComponent("shelf.json")).items.count == 2, "shelf: kept after a restart")
    let moved = shelfDir.appendingPathComponent("report-renamed.txt")
    try! FileManager.default.moveItem(at: f1, to: moved)
    let reportItem = sh.items.first { $0.name == "report.txt" }!
    check(sh.url(for: reportItem)?.lastPathComponent == "report-renamed.txt", "shelf: follows a file that was renamed")
    try! FileManager.default.removeItem(at: moved)
    check(sh.isMissing(reportItem), "shelf: a deleted file is shown as gone")
    check(hm.dropFiles([f3]) && hm.homeChoice == .shelf, "shelf: a drop adds the file and shows the shelf")
    sh.loadThumbnail(for: sh.items.first!)
    check(sh.thumbnails[sh.items.first!.id] != nil, "shelf: a picture of the file is shown at once")
    let thumbID = sh.items.first!.id
    check(waitUntil(5) { (sh.thumbnails[thumbID]?.size.width ?? 0) > 0 }, "shelf: and a real preview follows")
    sh.remove(sh.items.first!.id)
    check(sh.items.count == 2, "shelf: remove")
    for i in 0..<35 { _ = sh.add([makeFile("bulk\(i).txt", "x\(i)")]) }
    check(sh.items.count == ShelfStore.limit, "shelf: holds at most \(ShelfStore.limit) files")
    sh.clear()
    check(sh.items.isEmpty && ShelfStore(file: shelfDir.appendingPathComponent("shelf.json")).items.isEmpty, "shelf: clear empties it for good")
    let dragPB = NSPasteboard(name: NSPasteboard.Name("notchplus.test.drag"))
    dragPB.clearContents(); dragPB.writeObjects([f2 as NSURL])
    check(DragDetector.carriesFiles(dragPB), "drag: a drag carrying files is recognised")
    dragPB.clearContents(); dragPB.setString("just text", forType: .string)
    check(!DragDetector.carriesFiles(dragPB), "drag: a drag carrying only text is not")

    // pictures of the new states
    print("   pictures")
    func cover(_ a: NSColor, _ b: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 200, height: 200), flipped: false) { r in NSGradient(colors: [a, b])?.draw(in: r, angle: 50); return true }
    }
    var shown = playingInfo
    shown.artwork = cover(.systemPink, .systemIndigo); shown.artworkKey = 7
    for notch in [true, false] {
        let tag = notch ? "notch" : "flat"
        let g = NotchGeometry.fake(notch: notch)
        let sdef = UserDefaults(suiteName: "notchplus.tests.home2")!; sdef.removePersistentDomain(forName: "notchplus.tests.home2")
        let sm = NotchModel(rules: NotificationRules(defaults: sdef), defaults: sdef, shelf: ShelfStore(file: shelfDir.appendingPathComponent("shelf2.json")))
        sm.shelf.clear()
        let c = NotchWindowController(model: sm, geometry: g, liveMouse: false, openSettings: {})
        pump(0.3)
        sm.hovering = true
        snapshot(c, "\(tag)-home-shelf-empty")
        sm.dropTargeted = true
        snapshot(c, "\(tag)-home-shelf-drop", wait: 0.6)
        sm.dropTargeted = false
        _ = sm.shelf.add([makeFile("Contract final v3.docx"), makeFile("budget.csv"), makeFile("notes.md"), makeFile("Screenshot 2026-10-10.png"), makeFile("Quarterly report.pdf")])
        snapshot(c, "\(tag)-home-shelf-items", wait: 1.2)
        // several files selected
        sm.selection.select(Set(sm.shelf.items.prefix(3).map(\.id)))
        snapshot(c, "\(tag)-home-shelf-multi", wait: 0.7)
        sm.selection.select(Set([sm.shelf.items[0].id]))
        // the question box
        if let first = sm.shelf.items.first, let asker = sm.asker(for: first) {
            asker.engine = { r in AsyncThrowingStream { c in c.yield("The report is dated 12 October 2026 and shows revenue of 4.2 million, up 8 percent on the last quarter."); c.finish() } }
            sm.startAsking(first)
            snapshot(c, "\(tag)-home-ask-empty", wait: 0.7)
            asker.ask("Summarize this report")
            snapshot(c, "\(tag)-home-ask-answer", wait: 0.8)
            sm.stopAsking()
            asker.clear()
        }
        sm.homeChoice = nil
        // the Recent list
        sm.notifications = [
            note("Messages", "com.apple.mobilesms", "Sam", nil, "Drinks at 9?", .now, ago: 120),
            note("Mail", "com.apple.mail", "Weekly report", nil, "Your numbers for the week are in.", nil, ago: 1800),
            note("Xcode", "com.apple.dt.xcode", "Build Succeeded", nil, "Notch+ built in 31 seconds", nil, ago: 5400),
        ]
        sm.quietUnseen = 2
        snapshot(c, "\(tag)-home-recent-tab", wait: 0.5)
        sm.openRecent()
        snapshot(c, "\(tag)-home-recent", wait: 0.7)
        sm.notifications = []
        sm.homeChoice = nil
        sm.setNowPlaying(nil)
        sm.homeChoice = .player
        snapshot(c, "\(tag)-home-player-empty", wait: 0.6)
        sm.homeChoice = nil
        sm.setNowPlaying(shown)
        snapshot(c, "\(tag)-home-player", wait: 0.9)
        // with real-looking cover art and a title that is too long to fit
        let cover = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.95, green: 0.35, blue: 0.2, alpha: 1), NSColor(red: 0.98, green: 0.75, blue: 0.2, alpha: 1)])?.draw(in: r, angle: 55)
            NSColor(red: 0.1, green: 0.15, blue: 0.5, alpha: 0.9).setFill(); NSBezierPath(ovalIn: NSRect(x: 150, y: 40, width: 170, height: 170)).fill()
            return true
        }
        var withArt = shown; withArt.artwork = cover; withArt.artworkKey = 777
        withArt.title = "A very long song title that cannot possibly fit in the space it has been given"
        sm.setNowPlaying(withArt)
        snapshot(c, "\(tag)-home-player-art", wait: 1.3)
        sm.setNowPlaying(shown)
        sm.hovering = false
        pump(0.8)
        check(sm.state == .wings, "\(tag): music beside the notch")
        snapshot(c, "\(tag)-wings-music", wait: 0.6)
        // Claude starts working while the music plays: the music splits off into the drop
        sm.setNowPlaying(withArt)
        sm.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "drop", "cwd": "/tmp/notch-plus"])
        check(sm.musicBubble, "\(tag): music moves into the drop while Claude works")
        snapshot(c, "\(tag)-wings-music-drop", wait: 1.0)
        sm.sessions = [:]
        c.panel.orderOut(nil)
    }

    // MARK: 10. File actions on real files
    print("10. File actions")
    let fdir = base.appendingPathComponent("files"); try? FileManager.default.removeItem(at: fdir)
    try! FileManager.default.createDirectory(at: fdir, withIntermediateDirectories: true)

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
    func runAction(_ id: String, _ url: URL, wait: Double = 60) -> (result: ActionResult?, error: String?, progress: [ActionProgress]) {
        let res = Box<ActionResult?>(nil), err = Box<String?>(nil), prog = Box<[ActionProgress]>([]), done = Box(false)
        Task {
            do { res.value = try await FileActions.run(id, on: url) { p in prog.value.append(p) } }
            catch { err.value = error.localizedDescription }
            done.value = true
        }
        _ = waitUntil(wait) { done.value }
        return (res.value, done.value ? err.value : "timed out", prog.value)
    }
    func sha(_ u: URL) -> Int { (try? Data(contentsOf: u).hashValue) ?? -1 }
    func makeImage(_ name: String, w: Int, h: Int, draw: (CGContext, CGRect) -> Void) -> URL {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGRect(x: 0, y: 0, width: w, height: h))
        let u = fdir.appendingPathComponent(name)
        try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: u)
        return u
    }

    // kinds and menus
    check(FileKind.of(URL(fileURLWithPath: "/a/b.PNG")) == .image && FileKind.of(URL(fileURLWithPath: "/a/b.mp3")) == .audio && FileKind.of(URL(fileURLWithPath: "/a/b.mov")) == .video, "kinds: pictures, audio and video are recognised")
    check(FileKind.of(URL(fileURLWithPath: "/a/b.pdf")) == .pdf && FileKind.of(URL(fileURLWithPath: "/a/b.md")) == .text && FileKind.of(URL(fileURLWithPath: "/a/b.xyz123")) == .other, "kinds: PDF, text and unknown")
    check(FileActions.menu(for: .image).intelligence.map(\.id) == ["removeBackground", "extractText"], "menu: a picture offers remove background and extract text")
    check(FileActions.menu(for: .audio).intelligence.map(\.id).contains("transcribe") && !FileActions.menu(for: .audio).translate.isEmpty, "menu: audio offers transcribe and translate")
    check(FileActions.menu(for: .other).isEmpty, "menu: an unknown file offers nothing (no empty menu)")
    check(FileActions.menu(for: .pdf).intelligence.map(\.id).contains("extractText") && !FileActions.menu(for: .text).intelligence.map(\.id).contains("extractText"), "menu: only a PDF offers extract text")

    // pictures
    let words = makeImage("words.png", w: 1800, h: 400) { c, r in
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(r)
        let s = NSAttributedString(string: "NOTCH SHELF TEST 2026", attributes: [.font: NSFont.boldSystemFont(ofSize: 110), .foregroundColor: NSColor.black])
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        s.draw(at: NSPoint(x: 40, y: 140)); NSGraphicsContext.restoreGraphicsState()
    }
    let wordsHash = sha(words)
    var ra = runAction("extractText", words)
    print("         read: \((ra.result?.text ?? "nil").replacingOccurrences(of: "\n", with: " | "))")
    check(ra.result?.text?.uppercased().contains("NOTCH") == true && ra.result?.text?.contains("2026") == true, "pictures: text is read from a picture")
    check(ra.result?.files.first.map { FileManager.default.fileExists(atPath: $0.path) } == true, "pictures: the text is saved next to it")
    ra = runAction("extractText", words)
    check(ra.result?.files.first?.lastPathComponent == "words text 2.txt", "output names never overwrite (\(ra.result?.files.first?.lastPathComponent ?? "-"))")
    let blank = makeImage("blank.png", w: 400, h: 300) { c, r in c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(r) }
    ra = runAction("extractText", blank)
    check(ra.error?.contains("No text") == true, "pictures: no text gives a clear message")
    let subject = makeImage("subject.png", w: 900, h: 700) { c, r in
        let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.5, green: 0.7, blue: 0.9, alpha: 1), CGColor(red: 0.8, green: 0.9, blue: 1, alpha: 1)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: r.height), options: [])
        let ball = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 1, green: 0.3, blue: 0.2, alpha: 1), CGColor(red: 0.5, green: 0.05, blue: 0.05, alpha: 1)] as CFArray, locations: [0, 1])!
        c.saveGState(); c.addEllipse(in: CGRect(x: 280, y: 160, width: 340, height: 340)); c.clip()
        c.drawRadialGradient(ball, startCenter: CGPoint(x: 400, y: 400), startRadius: 0, endCenter: CGPoint(x: 450, y: 330), endRadius: 200, options: [.drawsAfterEndLocation])
        c.restoreGState()
    }
    ra = runAction("removeBackground", subject)
    if let out = ra.result?.files.first {
        let img = NSBitmapImageRep(data: try! Data(contentsOf: out))!
        let corner = img.colorAt(x: 5, y: 5)?.alphaComponent ?? 1, centre = img.colorAt(x: img.pixelsWide / 2, y: img.pixelsHigh / 2)?.alphaComponent ?? 0
        check(img.hasAlpha && corner < 0.1 && centre > 0.9, "pictures: the background becomes transparent and the subject stays (corner \(String(format: "%.2f", corner)), centre \(String(format: "%.2f", centre)))")
        check(out.lastPathComponent == "subject (no background).png", "pictures: named next to the original")
    } else {
        print("         remove background: \(ra.error ?? "?") (the test picture may be too simple for the subject finder)")
        check(ra.error?.contains("subject") == true, "pictures: no clear subject gives a clear message")
    }
    for fmt in ["jpeg", "png", "heic"] {
        ra = runAction("image:\(fmt)", words)
        if let f = ra.result?.files.first, let t = try? f.resourceValues(forKeys: [.contentTypeKey]).contentType {
            check(t.conforms(to: fmt == "jpeg" ? .jpeg : fmt == "heic" ? .heic : .png), "pictures: converted to \(fmt.uppercased())")
        } else { check(false, "pictures: converted to \(fmt.uppercased()) (\(ra.error ?? "?"))") }
    }
    let big = makeImage("big.png", w: 4000, h: 3000) { c, r in c.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.4, alpha: 1)); c.fill(r) }
    ra = runAction("image:small", big)
    if let f = ra.result?.files.first, let src = CGImageSourceCreateWithURL(f as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        check((p[kCGImagePropertyPixelWidth] as? Int ?? 9999) <= 2048, "pictures: 'make smaller' shrinks a big picture (\(p[kCGImagePropertyPixelWidth] ?? 0) px wide)")
    } else { check(false, "pictures: make smaller") }
    check(sha(words) == wordsHash, "pictures: the original is never changed")

    // audio, made with this Mac's own voice
    let speech = fdir.appendingPathComponent("speech.aiff")
    _ = run("/usr/bin/say", ["-o", speech.path, "Hello, this is a short test of the notch shelf. The weather is nice today, and we will go for a walk in the park."], maxWait: 30)
    check(FileManager.default.fileExists(atPath: speech.path), "audio: a spoken test file was made")
    let speechHash = sha(speech)
    ra = runAction("audio:m4a", speech)
    if let f = ra.result?.files.first {
        let d = (try? AVURLAsset(url: f).duration.seconds) ?? 0
        check(f.pathExtension == "m4a" && d > 3, "audio: converted to M4A (\(String(format: "%.1f", d)) s)")
        check((ra.progress.compactMap(\.fraction).last ?? 0) > 0.9, "audio: progress reached the end")
    } else { check(false, "audio: converted to M4A (\(ra.error ?? "?"))") }
    ra = runAction("audio:wav", speech)
    if let f = ra.result?.files.first, let af = try? AVAudioFile(forReading: f) {
        check(f.pathExtension == "wav" && af.length > 20000, "audio: converted to WAV (\(af.length) frames)")
    } else { check(false, "audio: converted to WAV (\(ra.error ?? "?"))") }
    check(sha(speech) == speechHash, "audio: the original is never changed")

    print("   speech and language (on-device, may take a moment)")
    ra = runAction("transcribe", speech, wait: 120)
    if let res = ra.result {
        let t = (res.text ?? "").lowercased()
        print("         heard: \((res.text ?? "").prefix(110))")
        check(t.contains("test") && t.contains("weather"), "speech: the words are heard")
        check(res.files.count == 2 && res.files.contains { $0.pathExtension == "srt" } && res.files.contains { $0.pathExtension == "txt" }, "speech: a text file and subtitles are saved")
        if let srt = res.files.first(where: { $0.pathExtension == "srt" }), let s = try? String(contentsOf: srt, encoding: .utf8) {
            check(s.hasPrefix("1\n00:00:") && s.contains(" --> "), "speech: the subtitles are in proper .srt form")
        }
        check(ra.progress.contains { $0.status.contains("“") } || ra.progress.count > 1, "speech: progress was reported along the way")
    } else { check(false, "speech: transcribed (\(ra.error ?? "?"))") }

    let para = "The notch shelf is a small place to park files. You drag a file to the notch, and it stays there. Later you can drag it into any app. The shelf only keeps links, so your files are never copied or moved. Right-clicking a file shows what the Mac can do with it on its own: remove a background, read text from a picture, transcribe a recording, translate a document, or write a short summary. Everything happens on the Mac, nothing is sent anywhere, and the results are saved next to the original file."
    let textFile = fdir.appendingPathComponent("about.txt"); try! para.write(to: textFile, atomically: true, encoding: .utf8)
    ra = runAction("summarize", textFile, wait: 90)
    if Intelligence.isAvailable {
        let s = ra.result?.text ?? ""
        print("         summary: \(s.prefix(160).replacingOccurrences(of: "\n", with: " | "))")
        check(s.count > 30 && s.count < para.count, "summary: a shorter summary is written (\(s.count) of \(para.count) characters)")
        check(ra.result?.files.first?.lastPathComponent == "about summary.txt", "summary: saved next to the file")
    } else { check(ra.error?.contains("Apple Intelligence") == true, "summary: says clearly when Apple Intelligence is unavailable") }
    let longText = fdir.appendingPathComponent("long.txt")
    try! (0..<60).map { "Paragraph \($0): The team reviewed the budget for region \($0 % 7) and agreed to move the launch date to week \($0 % 12 + 1) because the supplier was late." }.joined(separator: "\n").write(to: longText, atomically: true, encoding: .utf8)
    ra = runAction("summarize", longText, wait: 180)
    if Intelligence.isAvailable {
        check((ra.result?.text ?? "").count > 30, "summary: a long text is summarised piece by piece (\((ra.result?.text ?? ra.error ?? "").prefix(80)))")
        check((ra.progress.compactMap(\.fraction).last ?? 0) >= 0.99, "summary: progress ends at 100%")
    }

    // PDF
    let pdfURL = fdir.appendingPathComponent("letter.pdf")
    do {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
        NSAttributedString(string: "Invoice 4471 for the notch shelf project. Total due: 1250 dollars.", attributes: [.font: NSFont.systemFont(ofSize: 16)]).draw(in: CGRect(x: 60, y: 600, width: 480, height: 100))
        NSGraphicsContext.restoreGraphicsState()
        pdf.endPDFPage(); pdf.closePDF()
    }
    ra = runAction("extractText", pdfURL)
    check(ra.result?.text?.contains("4471") == true, "pdf: the text of a PDF is read")
    // a scanned PDF (only a picture of the words)
    let scanURL = fdir.appendingPathComponent("scan.pdf")
    do {
        let img = NSImage(contentsOf: words)!
        let doc = PDFDocument(); doc.insert(PDFPage(image: img)!, at: 0); doc.write(to: scanURL)
    }
    ra = runAction("extractText", scanURL)
    check(ra.result?.text?.uppercased().contains("NOTCH") == true, "pdf: a scanned page is read with text recognition")

    // translation (needs the language installed in System Settings)
    let hello = fdir.appendingPathComponent("hello.txt"); try! "Good morning. The weather is nice today.".write(to: hello, atomically: true, encoding: .utf8)
    ra = runAction("translate:es", hello)
    if let t = ra.result?.text {
        print("         translated: \(t)")
        check(!t.isEmpty && t != "Good morning. The weather is nice today.", "translate: text is translated to Spanish")
        check(ra.result?.files.first?.lastPathComponent == "hello (Spanish).txt", "translate: saved next to the file")
    } else {
        print("         translate: \(ra.error ?? "?")")
        check(ra.error?.contains("installed") == true, "translate: says clearly when a language is not installed")
    }
    ra = runAction("translate:en", hello)
    check(ra.error?.contains("already") == true, "translate: the same language is refused politely")

    // MARK: 11. Running actions from the shelf
    print("11. Actions in the app")
    let jdef = UserDefaults(suiteName: "notchplus.tests.jobs")!; jdef.removePersistentDomain(forName: "notchplus.tests.jobs")
    let jdir = base.appendingPathComponent("jobs"); try? FileManager.default.removeItem(at: jdir)
    try! FileManager.default.createDirectory(at: jdir, withIntermediateDirectories: true)
    let origFile = jdir.appendingPathComponent("photo.png"); try! Data("pretend picture".utf8).write(to: origFile)
    let jm = NotchModel(rules: NotificationRules(defaults: jdef), defaults: jdef, shelf: ShelfStore(file: jdir.appendingPathComponent("shelf.json")))
    _ = jm.shelf.add([origFile])
    let item = jm.shelf.items[0]
    let producedFile = jdir.appendingPathComponent("photo (no background).png"); try! Data("result".utf8).write(to: producedFile)
    let gate = Box(true)
    jm.runner = { id, url, sink in
        sink(ActionProgress(fraction: 0.2, status: "Finding the subject…"))
        while gate.value { try await Task.sleep(for: .milliseconds(20)) }
        sink(ActionProgress(fraction: 0.8, status: "Almost…"))
        if id == "fail" { throw ActionError(message: "No clear subject was found in this picture.") }
        return ActionResult(title: "Background removed", files: [producedFile], text: id == "text" ? "Hello from the picture" : nil)
    }
    jm.startAction("removeBackground", on: item)
    check(jm.jobs.count == 1 && jm.job(for: item.id)?.verb == "Removing background", "actions: starting one shows a running job on the file")
    check(waitUntil { jm.job(for: item.id)?.fraction == 0.2 }, "actions: progress reaches the job")
    check(jm.state == .wings, "actions: progress shows beside the notch")
    jm.startAction("removeBackground", on: item)
    check(jm.jobs.count == 1, "actions: the same file cannot be started twice")
    jm.handleEvent(["hook_event_name": "UserPromptSubmit", "session_id": "j", "cwd": "/tmp"])
    check(jm.liveSession != nil && jm.state == .wings, "actions: Claude working and a job can both run")
    jm.sessions = [:]
    jm.hovering = true
    check(jm.state == .overview, "actions: opening the island still works while a job runs")
    jm.hovering = false
    gate.value = false
    check(waitUntil { jm.jobs.isEmpty && jm.outcome != nil }, "actions: when it finishes the job ends and a result card shows")
    check(jm.state == .result, "actions: the result card opens the island")
    if case .done(let res, let source)? = jm.outcome { check(res.title == "Background removed" && source == "photo.png", "actions: the card names the result and the file") } else { check(false, "actions: done outcome") }
    check(jm.shelf.items.contains { $0.name == "photo (no background).png" }, "actions: the result is added to the shelf, ready to drag out")
    jm.dismissOutcome()
    check(jm.state == .closed, "actions: dismissing the card closes the island")

    gate.value = false
    jm.startAction("fail", on: item)
    check(waitUntil { jm.outcome != nil }, "actions: a failing action reports back")
    if case .failed(let msg, _)? = jm.outcome { check(msg.contains("No clear subject"), "actions: the failure says why in plain words") } else { check(false, "actions: failed outcome") }
    jm.dismissOutcome()
    jm.startAction("text", on: item)
    check(waitUntil { jm.outcome != nil }, "actions: a text result comes back")
    if case .done(let res, _)? = jm.outcome { check(res.text == "Hello from the picture", "actions: the text is kept for the card") }
    jm.showOutcome(.done(ActionResult(title: "x", files: [], text: nil), source: "y"), seconds: 0.2)
    pump(0.5)
    check(jm.outcome == nil, "actions: a result card goes away by itself")
    jm.shelf.remove(item.id)
    jm.startAction("removeBackground", on: item)
    check(jm.jobs.isEmpty, "actions: a file that left the shelf cannot be started")
    check(NotchModel.verb(for: "transcribe:ru-RU") == "Transcribing" && NotchModel.verb(for: "translate:es") == "Translating" && NotchModel.verb(for: "audio:wav") == "Converting", "actions: verbs read naturally")

    // pictures of the new states
    print("   pictures")
    for notch in [true, false] {
        let tag = notch ? "notch" : "flat"
        let g = NotchGeometry.fake(notch: notch)
        let vdef = UserDefaults(suiteName: "notchplus.tests.jobs2")!; vdef.removePersistentDomain(forName: "notchplus.tests.jobs2")
        let vm = NotchModel(rules: NotificationRules(defaults: vdef), defaults: vdef, shelf: ShelfStore(file: jdir.appendingPathComponent("shelf-v.json")))
        vm.shelf.clear()
        let files = ["Interview.m4a", "Holiday.png", "Contract.pdf"].map { n -> URL in let u = jdir.appendingPathComponent(n); try! Data("x".utf8).write(to: u); return u }
        _ = vm.shelf.add(files)
        let c = NotchWindowController(model: vm, geometry: g, liveMouse: false, openSettings: {})
        pump(0.3)
        let hold = Box(true)
        vm.runner = { _, _, sink in
            sink(ActionProgress(fraction: 0.42, status: "“…and then we walked into the market”"))
            while hold.value { try await Task.sleep(for: .milliseconds(20)) }
            return ActionResult(title: "Transcribed", files: [jdir.appendingPathComponent("Interview transcript.txt"), jdir.appendingPathComponent("Interview.srt")],
                                text: "Hello, thanks for having me. I wanted to talk about how the shelf works and why it keeps only links to your files.\n\nThe first thing people notice is that nothing is copied or moved.")
        }
        vm.hovering = true
        vm.homeChoice = .shelf
        pump(0.6)
        vm.startAction("transcribe", on: vm.shelf.items.first { $0.name == "Interview.m4a" }!)
        snapshot(c, "\(tag)-job-ring", wait: 0.8)
        vm.hovering = false
        pump(0.8)
        check(vm.state == .wings, "\(tag): a running job shows beside the notch")
        snapshot(c, "\(tag)-job-wings", wait: 0.4)
        hold.value = false
        pump(0.8)
        check(vm.state == .result, "\(tag): the finished job opens a result card")
        snapshot(c, "\(tag)-result-text", wait: 0.8)
        vm.showOutcome(.failed("No clear subject was found in this picture.", source: "Holiday.png"))
        snapshot(c, "\(tag)-result-failed", wait: 0.8)
        vm.showOutcome(.done(ActionResult(title: "Background removed", files: [jdir.appendingPathComponent("Holiday (no background).png")], text: nil), source: "Holiday.png"))
        snapshot(c, "\(tag)-result-file", wait: 0.8)
        vm.dismissOutcome()
        pump(0.5)
        c.panel.orderOut(nil)
    }

    // MARK: 12. Ask this file
    print("12. Ask this file")
    // the chunker and retrieval (no model)
    let askParas = (0..<40).map { "Paragraph \($0) is about gardening, soil and watering the plants every morning in spring." }
    var askDoc = askParas
    askDoc[27] = "The invoice total is 4,820 euros and payment is due on 14 March 2027 to Bluebird Logistics."
    let askLong = askDoc.joined(separator: "\n")
    let askChunks = TextChunker.split(askLong, size: 600)
    check(askChunks.count > 3 && askChunks.allSatisfy { $0.count <= 1300 }, "ask: a long text is cut into pieces (\(askChunks.count))")
    let askPicked = TextChunker.relevant(askChunks, to: "When is the payment due and what is the invoice total?", budget: 1500)
    check(askPicked.joined().contains("14 March 2027") && askPicked.joined().count <= 1700, "ask: the piece that answers the question is picked, within the budget")
    check(askPicked.first == askChunks.first, "ask: the opening of the file is kept when there is room")
    check(TextChunker.relevant(askChunks, to: "anything", budget: 1_000_000) == askChunks, "ask: a file that fits is given whole")
    check(TextChunker.relevant([], to: "x", budget: 100).isEmpty, "ask: an empty file gives nothing")
    check(TextChunker.words("What is the TOTAL, please?") == ["total"], "ask: filler words are ignored when matching")

    // the conversation, with a made-up engine
    let askDir = base.appendingPathComponent("ask"); try? FileManager.default.removeItem(at: askDir)
    try! FileManager.default.createDirectory(at: askDir, withIntermediateDirectories: true)
    let askText = askDir.appendingPathComponent("lease.txt")
    try! "Rent is 1,250 dollars a month. The lease ends on 31 August 2027. The landlord is Mr Okafor.".write(to: askText, atomically: true, encoding: .utf8)
    let fake = FileAsker(url: askText)
    final class Seen: @unchecked Sendable { var requests: [AskRequest] = [] }
    let seen = Seen()
    fake.engine = { r in
        seen.requests.append(r)
        return AsyncThrowingStream { c in
            c.yield("Thinking")
            c.yield("It is \(r.question.count) characters long.")
            c.finish()
        }
    }
    check(FileAsker.canAsk(.pdf) && FileAsker.canAsk(.image) && FileAsker.canAsk(.text) && FileAsker.canAsk(.audio) && FileAsker.canAsk(.video) && !FileAsker.canAsk(.other), "ask: pictures, PDFs, text, audio and video can be asked about")
    fake.ask("   ")
    check(fake.turns.isEmpty, "ask: an empty question does nothing")
    fake.ask("How much is the rent?")
    check(fake.busy, "ask: busy while it answers")
    _ = waitUntil(3) { !fake.busy }
    check(fake.turns.count == 1 && fake.turns[0].finished && fake.turns[0].answer == "It is 21 characters long." && !fake.turns[0].failed, "ask: the answer grows, then the last one stands")
    fake.ask("And the end date?")
    _ = waitUntil(3) { !fake.busy }
    check(seen.requests.count == 2 && seen.requests[1].history.count == 1 && seen.requests[1].history[0].question == "How much is the rent?", "ask: a follow-up carries the earlier question and answer")
    check(fake.lastAnswer == fake.turns[1].answer, "ask: the last answer can be copied")
    fake.engine = { _ in AsyncThrowingStream { c in c.finish(throwing: ActionError(message: "Nope.")) } }
    fake.ask("Will this fail?")
    _ = waitUntil(3) { !fake.busy }
    check(fake.turns.last?.failed == true && fake.turns.last?.answer == "Nope." && !fake.busy, "ask: a failure says why and frees the box")
    fake.engine = { _ in AsyncThrowingStream { c in c.finish() } }
    fake.ask("Silent?")
    _ = waitUntil(3) { !fake.busy }
    check(fake.turns.last?.failed == true && !(fake.turns.last?.answer.isEmpty ?? true), "ask: no answer at all is reported, not left blank")

    // the real model on this Mac
    final class AskBox: @unchecked Sendable { var text = ""; var error: String?; var done = false }
    func realAnswer(_ url: URL, _ q: String, history: [(question: String, answer: String)] = [], wait: Double = 90) -> AskBox {
        let b = AskBox()
        let req = AskRequest(url: url, kind: FileKind.of(url), question: q, history: history)
        Task {
            do { for try await t in Intelligence.answerAboutFile(req) { b.text = t } } catch { b.error = error.localizedDescription }
            b.done = true
        }
        _ = waitUntil(wait) { b.done }
        return b
    }
    if Intelligence.isAvailable {
        let a1 = realAnswer(askText, "How much is the monthly rent?")
        check(a1.text.contains("1,250") || a1.text.contains("1250"), "ask (real): a text file is answered correctly: \(a1.text)")
        let a2 = realAnswer(askText, "Who is the landlord?")
        check(a2.text.contains("Okafor"), "ask (real): a name is found: \(a2.text)")
        let a3 = realAnswer(askText, "What colour is the front door?")
        check(a3.text.lowercased().contains("isn't in this file") || a3.text.lowercased().contains("not in this file") || a3.text.lowercased().contains("doesn't") || a3.text.lowercased().contains("does not"), "ask (real): something the file does not say is admitted: \(a3.text)")
        // a document far longer than the model can read at once
        let bigURL = askDir.appendingPathComponent("big.txt")
        try! askLong.write(to: bigURL, atomically: true, encoding: .utf8)
        let hugeURL = askDir.appendingPathComponent("huge.txt")
        try! ((0..<6).map { _ in askLong }.joined(separator: "\n") + "\nThe secret word for the vault is PELICAN.").write(to: hugeURL, atomically: true, encoding: .utf8)
        let a4 = realAnswer(bigURL, "When is the payment due, and to whom?")
        check(a4.text.contains("14 March") && a4.text.contains("Bluebird"), "ask (real): a long file is searched for the answer: \(a4.text)")
        let a5 = realAnswer(hugeURL, "What is the secret word for the vault?")
        check(a5.text.uppercased().contains("PELICAN"), "ask (real): a file of about \(6 * askLong.count / 1000)k characters still answers: \(a5.text)")
        // a picture, looked at directly
        let rimg = NSImage(size: NSSize(width: 700, height: 420), flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            "CORNER CAFE\nLatte            4.50\nCroissant        3.75\nSandwich        11.25\nTOTAL           19.50\nPaid by card".draw(in: r.insetBy(dx: 30, dy: 20), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 34, weight: .medium), .foregroundColor: NSColor.black])
            return true
        }
        let rpng = askDir.appendingPathComponent("receipt.png")
        if let tiff = rimg.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try! png.write(to: rpng) }
        let a6 = realAnswer(rpng, "What is the total?")
        check(a6.text.contains("19.50") || a6.text.contains("19.5"), "ask (real): a receipt picture is read and answered: \(a6.text)")
        let a7 = realAnswer(rpng, "And how many items were bought?", history: [(question: "What is the total?", answer: a6.text)])
        check(a7.text.contains("3") || a7.text.lowercased().contains("three"), "ask (real): a follow-up about the picture works: \(a7.text)")
        let missing = realAnswer(askDir.appendingPathComponent("nothing.txt"), "Anything?")
        check(missing.error != nil, "ask (real): a missing file gives a clear error: \(missing.error ?? "")")
    } else {
        print("  (Apple Intelligence not available: real answers skipped)")
    }

    check(LoginItem.state(for: .enabled) == .on && LoginItem.state(for: .notRegistered) == .off && LoginItem.state(for: .requiresApproval) == .needsApproval && LoginItem.state(for: .notFound) == .off, "login: system states map to on, off and needs approval (a never-registered app reports not found and can still be switched on)")
    // audio and video: transcribed first (made-up transcriber), then asked
    do {
        let audioURL = askDir.appendingPathComponent("talk.m4a"); try! Data().write(to: audioURL)
        let aa = FileAsker(url: audioURL)
        final class Calls: @unchecked Sendable { var n = 0 }
        let calls = Calls()
        var texts: [String?] = []
        aa.transcriber = { _, report in calls.n += 1; report("Listening… 50%"); return "Sara says the meeting moves to Friday at 3pm." }
        aa.engine = { r in texts.append(r.text); return AsyncThrowingStream { c in c.yield("Friday at 3pm."); c.finish() } }
        aa.ask("When is the meeting?")
        _ = waitUntil(3) { !aa.busy }
        check(calls.n == 1 && texts == ["Sara says the meeting moves to Friday at 3pm."] && aa.turns[0].answer == "Friday at 3pm." && aa.turns[0].status.isEmpty, "ask: an audio file is transcribed first, then the answer uses the words")
        aa.ask("Who said it?")
        _ = waitUntil(3) { !aa.busy }
        check(calls.n == 1 && aa.turns.count == 2, "ask: the second question reuses the transcript (no second transcription)")
        let ab = FileAsker(url: audioURL)
        ab.transcriber = { _, _ in throw ActionError(message: "No speech was found in this file.") }
        ab.ask("Anything?")
        _ = waitUntil(3) { !ab.busy }
        check(ab.turns[0].failed && ab.turns[0].answer == "No speech was found in this file.", "ask: a file with no speech says so")
    }
    if Intelligence.isAvailable {
        let spoken = askDir.appendingPathComponent("spoken.aiff")
        _ = run("/usr/bin/say", ["-o", spoken.path, "The quarterly meeting has moved to Thursday at four thirty. Please bring the signed contract and the budget for the Lisbon office."], maxWait: 30)
        let real = FileAsker(url: spoken)
        real.ask("When is the meeting?")
        _ = waitUntil(150) { !real.busy }
        let r1 = real.turns.first
        check(r1?.failed == false && ((r1?.answer.lowercased().contains("thursday")) ?? false), "ask (real): speech is transcribed on this Mac and the question answered: \(r1?.answer ?? "nothing")")
        real.ask("What should I bring?")
        _ = waitUntil(60) { !real.busy }
        let r2 = real.turns.last
        check(r2?.failed == false && ((r2?.answer.lowercased().contains("contract")) ?? false), "ask (real): a follow-up about the audio works: \(r2?.answer ?? "nothing")")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: askDir.path)) ?? []
        check(!written.contains { $0.contains("transcript") || $0.hasSuffix(".srt") }, "ask (real): asking writes no transcript files next to the original")
    }

    // the floating basket
    func shakeRun(amplitude: CGFloat, sweeps: Int, seconds: Double, fps: Double = 120) -> Bool {
        var d = ShakeDetector()
        let n = Int(seconds * fps)
        var hit = false
        for i in 0..<n {
            let t = Double(i) / fps
            let phase = t / seconds * Double(sweeps) * .pi
            let x = 500 + amplitude * CGFloat(sin(phase - .pi / 2)) * 1.0
            if d.feed(x: x, at: t) { hit = true }
        }
        return hit
    }
    check(shakeRun(amplitude: 80, sweeps: 6, seconds: 0.7), "basket: a quick left-right shake is recognised")
    check(!shakeRun(amplitude: 80, sweeps: 1, seconds: 0.6), "basket: one sweep across is not a shake")
    check(!shakeRun(amplitude: 8, sweeps: 12, seconds: 0.8), "basket: a tiny tremble is not a shake")
    check(!shakeRun(amplitude: 80, sweeps: 6, seconds: 6), "basket: slow swinging over many seconds is not a shake")
    var straight = ShakeDetector(); var straightHit = false
    for i in 0..<60 { if straight.feed(x: CGFloat(i) * 14, at: Double(i) / 120) { straightHit = true } }
    check(!straightHit, "basket: a fast straight drag is not a shake")
    let scr = CGRect(x: 0, y: 0, width: 1500, height: 900)
    let pf = BasketPlacement.frame(cursor: CGPoint(x: 700, y: 400), size: CGSize(width: 372, height: 214), in: scr)
    check(abs(pf.midX - 700) < 0.5 && pf.minY > 300 && pf.maxY < 700, "basket: it appears around the pointer")
    let corner = BasketPlacement.frame(cursor: CGPoint(x: 5, y: 5), size: CGSize(width: 372, height: 214), in: scr)
    let far = BasketPlacement.frame(cursor: CGPoint(x: 1499, y: 899), size: CGSize(width: 372, height: 214), in: scr)
    check(scr.contains(corner) && scr.contains(far) && corner.minX >= 10 && far.maxX <= 1490, "basket: near a screen corner it stays fully on the screen")

    // selecting several files
    do {
        let o = (0..<6).map { _ in UUID() }
        var sel = ShelfSelection()
        sel.click(o[1], order: o, command: false, shift: false)
        check(sel.ids == [o[1]] && sel.anchor == o[1], "select: a click selects one file")
        sel.click(o[3], order: o, command: true, shift: false)
        check(sel.ids == [o[1], o[3]], "select: Command-click adds another")
        sel.click(o[1], order: o, command: true, shift: false)
        check(sel.ids == [o[3]], "select: Command-click on a selected file removes it")
        sel.click(o[0], order: o, command: false, shift: false)
        sel.click(o[3], order: o, command: false, shift: true)
        check(sel.ids == Set(o[0...3]), "select: Shift-click selects the whole range")
        sel.click(o[5], order: o, command: false, shift: true)
        check(sel.ids == Set(o[0...5]) && sel.anchor == o[0], "select: the range can be stretched from the same start")
        sel.click(o[2], order: o, command: false, shift: true)
        check(sel.ids == Set(o[0...2]), "select: and shrunk again")
        sel.selectAll(o)
        check(sel.count == 6, "select: select all")
        sel.prune(keeping: Array(o[0...2]))
        check(sel.ids == Set(o[0...2]), "select: files that went away are dropped from the selection")
        check(sel.ordered(o) == Array(o[0...2]), "select: the selection comes back in display order")
        sel.clear()
        check(sel.isEmpty && sel.anchor == nil, "select: clear")
    }

    // the basket and the shelf: one list or two, and several files at once
    do {
        let sdir = askDir.appendingPathComponent("lists"); try? FileManager.default.removeItem(at: sdir)
        try! FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true)
        UserDefaults(suiteName: "notchplus.tests.lists")!.removePersistentDomain(forName: "notchplus.tests.lists")
        let lm = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.lists")!), defaults: UserDefaults(suiteName: "notchplus.tests.lists")!,
                            shelf: ShelfStore(file: sdir.appendingPathComponent("shelf.json")), basketStore: ShelfStore(file: sdir.appendingPathComponent("basket.json")))
        func mk(_ name: String, in dir: URL? = nil) -> URL {
            let d = dir ?? sdir
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let u = d.appendingPathComponent(name); try! "data of \(name)".write(to: u, atomically: true, encoding: .utf8); return u
        }
        let f1 = mk("a.txt"), f2 = mk("b.txt"), f3 = mk("c.txt"), f4 = mk("a.txt", in: sdir.appendingPathComponent("other"))
        check(!lm.basketSendsToShelf && lm.basketList === lm.basketStore, "basket: by default it keeps its own list, nothing goes to the shelf")
        lm.add([f1], to: lm.basketList); lm.sendToShelf(lm.basketStore.items.map(\.id))
        check(lm.basketStore.items.isEmpty && lm.shelf.items.count == 1, "basket: To shelf moves the chosen files onto the shelf")
        lm.shelf.clear()
        lm.basketSendsToShelf = true
        lm.add([f1, f2, f3], to: lm.basketList)
        check(lm.shelf.items.count == 3 && lm.selection.count == 3, "basket: files dropped in go on the shelf, and the new ones are all selected")
        lm.selection.clear()
        let order = lm.shelf.items.map(\.id)
        lm.clickFile(order[0], in: lm.shelf, command: false, shift: false)
        lm.clickFile(order[2], in: lm.shelf, command: true, shift: false)
        check(lm.selection.ids == [order[0], order[2]], "select: clicking on the shelf follows the Command rule")
        // separate lists
        lm.basketSendsToShelf = false
        check(lm.basketList === lm.basketStore, "basket: with the toggle off it uses its own list")
        lm.add([f4], to: lm.basketList)
        check(lm.basketStore.items.count == 1 && lm.shelf.items.count == 3, "basket: with the toggle off, a dropped file stays out of the shelf")
        let bid = lm.basketStore.items[0].id
        check(lm.store(containing: bid) === lm.basketStore && lm.store(containing: order[0]) === lm.shelf, "basket: each file is found in its own list")
        // an action on a basket-only file puts its result in the basket, not on the shelf
        lm.runner = { _, url, _ in
            let out = url.deletingLastPathComponent().appendingPathComponent("result-of-\(url.lastPathComponent)")
            try "result".write(to: out, atomically: true, encoding: .utf8)
            return ActionResult(title: "Done", files: [out], text: nil)
        }
        lm.startAction("summarize", on: lm.basketStore.items[0])
        _ = waitUntil(5) { lm.jobs.isEmpty }
        check(lm.basketStore.items.count == 2 && lm.shelf.items.count == 3, "basket: an action's result lands in the basket, next to the original")
        lm.dismissOutcome()
        // switching back moves the basket's own files to the shelf
        lm.basketSendsToShelf = true
        check(lm.basketStore.items.isEmpty && lm.shelf.items.count == 5, "basket: turning the toggle back on moves its own files to the shelf")
        // dragging several out
        lm.shelfRemoveAfterDragOut = true
        let some = Array(lm.shelf.items.prefix(3).map(\.id))
        lm.dragOutEnded(some, droppedSomewhere: false)
        check(lm.shelf.items.count == 5, "select: a cancelled multi-file drag removes nothing")
        lm.dragOutEnded(some, droppedSomewhere: true)
        check(lm.shelf.items.count == 2 && FileManager.default.fileExists(atPath: f1.path) && FileManager.default.fileExists(atPath: f2.path), "select: after dropping 3 files elsewhere they leave the shelf, the files themselves stay")
    }

    // zip
    do {
        let zdir = askDir.appendingPathComponent("zip"); try? FileManager.default.removeItem(at: zdir)
        try! FileManager.default.createDirectory(at: zdir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let z1 = zdir.appendingPathComponent("notes.txt"); try! "one".write(to: z1, atomically: true, encoding: .utf8)
        let z2 = zdir.appendingPathComponent("sub/notes.txt"); try! "two".write(to: z2, atomically: true, encoding: .utf8)
        let z3 = zdir.appendingPathComponent("sub"); try! "three".write(to: z3.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        UserDefaults(suiteName: "notchplus.tests.zip")!.removePersistentDomain(forName: "notchplus.tests.zip")
        let zm = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.zip")!), defaults: UserDefaults(suiteName: "notchplus.tests.zip")!,
                            shelf: ShelfStore(file: zdir.appendingPathComponent("shelf.json")), basketStore: ShelfStore(file: zdir.appendingPathComponent("basket.json")))
        _ = zm.shelf.add([z1, z2, z3])
        check(zm.shelf.items.count == 3, "zip: three things on the shelf (two files with the same name, and a folder)")
        zm.startZip(Array(zm.shelf.items.prefix(1)))
        check(zm.jobs.isEmpty, "zip: one file alone is not zipped")
        zm.startZip(zm.shelf.items)
        check(zm.jobs.count == 1 && zm.jobs[0].verb == "Zipping", "zip: it runs as a background job")
        _ = waitUntil(20) { zm.jobs.isEmpty }
        let zips = ((try? FileManager.default.contentsOfDirectory(atPath: zdir.path)) ?? []).filter { $0.hasSuffix(".zip") }
        check(zips.count == 1, "zip: one archive is made next to the files (\(zips))")
        if let name = zips.first {
            let listing = run("/usr/bin/unzip", ["-Z1", zdir.appendingPathComponent(name).path]).out
            check(listing.contains("notes.txt") && listing.contains("notes 2.txt") && listing.contains("inner.txt"), "zip: both same-named files are inside under different names, and the folder's contents too")
        }
        let z1Text = try? String(contentsOf: z1, encoding: .utf8), z2Text = try? String(contentsOf: z2, encoding: .utf8)
        check(z1Text == "one" && z2Text == "two", "zip: the originals are untouched")
        check(zm.shelf.items.count == 4, "zip: the archive appears on the shelf, ready to drag")
        if case .done(let r, _)? = zm.outcome { check(r.title == "Zipped 3 files", "zip: the result card says what happened") } else { check(false, "zip: a result card is shown") }
        zm.dismissOutcome()
    }

    // the floating player
    do {
        UserDefaults(suiteName: "notchplus.tests.floating")!.removePersistentDomain(forName: "notchplus.tests.floating")
        let fm2 = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.floating")!), defaults: UserDefaults(suiteName: "notchplus.tests.floating")!)
        let screen = CGRect(x: -6000, y: 40, width: 1512, height: 900)
        let fp = FloatingPlayerController(model: fm2, visibleFrame: { screen })
        fp.start()
        pump(0.2)
        check(!fm2.floatingPlayerOn && !fp.isShown, "floating: off by default, nothing on screen")
        fm2.floatingPlayerOn = true; pump(0.3)
        check(!fp.isShown, "floating: switched on but nothing playing, it stays away")
        fm2.setNowPlaying(playingInfo); pump(0.5)
        check(fp.isShown && screen.contains(fp.panel!.frame), "floating: when something plays it appears on the screen")
        check(abs(fp.panel!.frame.maxX - (screen.maxX - 12)) < 1 && abs(fp.panel!.frame.minY - (screen.minY + 12)) < 1, "floating: the first time it sits in the bottom right corner")
        check(fp.panel?.canBecomeKey == false && fp.panel?.level == .floating, "floating: it floats above windows and never takes the keyboard")
        var paused3 = playingInfo; paused3.playing = false
        fm2.setNowPlaying(paused3); pump(0.4)
        check(fp.isShown, "floating: paused, it stays so play can be pressed")
        if let v = fp.panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            fm2.setNowPlaying(playingInfo); pump(0.6)
            v.cacheDisplay(in: v.bounds, to: rep)
            let cs = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.20, green: 0.30, blue: 0.52, alpha: 1), CGColor(red: 0.55, green: 0.36, blue: 0.48, alpha: 1)] as CFArray, locations: [0, 1]),
               let cg = rep.cgImage {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(rep.pixelsHigh)), end: CGPoint(x: CGFloat(rep.pixelsWide), y: 0), options: [])
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: snapDir.appendingPathComponent("floating-player.png")) }
            }
        }
        // moved by the user: remembered
        fp.panel?.setFrameOrigin(CGPoint(x: -5400, y: 300)); pump(0.4)
        check(fm2.defaults.object(forKey: "floatingPlayerX") as? Double == -5400 && fm2.defaults.object(forKey: "floatingPlayerY") as? Double == 300, "floating: where you drag it is remembered")
        fm2.setNowPlaying(nil); pump(0.6)
        check(!fp.isShown, "floating: when the player goes away it tucks away")
        fm2.setNowPlaying(playingInfo); pump(0.5)
        check(fp.isShown && abs(fp.panel!.frame.origin.x - (-5400)) < 1 && abs(fp.panel!.frame.origin.y - 300) < 1, "floating: it comes back where you left it")
        // pulled out of the notch: lands under the pointer
        fm2.floatingPlayerOn = false; pump(0.5)
        fm2.tearOffPlayer(); pump(0.2)
        check(fm2.floatingPlayerOn && fp.isShown, "floating: dragging the player out of the notch turns it on, no settings needed")
        fp.panel?.setFrameOrigin(CGPoint(x: -5000, y: 400)); pump(0.1)
        // let go at the notch: back in
        fp.settle(mouse: CGPoint(x: screen.midX, y: screen.maxY - 10)); pump(0.6)
        check(!fm2.floatingPlayerOn && !fp.isShown, "floating: let go up at the notch, it goes back in (on \(fm2.floatingPlayerOn), shown \(fp.isShown))")
        // let go in the middle of the screen: it stays, and clings to a close edge
        fm2.floatingPlayerOn = true; pump(0.4)
        fm2.floatingCompact = false; pump(0.6)
        let cs0 = FloatingPlayerController.contentSize(compact: false), ws0 = FloatingPlayerController.windowSize(compact: false)
        let nearEdge = CGRect(x: screen.minX - (ws0.width - cs0.width) / 2 + 9, y: screen.midY, width: ws0.width, height: ws0.height)
        let snap0 = fp.snapped(nearEdge)
        check(abs(snap0.origin.x + (ws0.width - cs0.width) / 2 - (screen.minX + FloatingPlayerController.snapMargin)) < 0.5 && snap0.origin.y == nearEdge.origin.y, "floating: near a screen edge it clings to it, elsewhere it stays put")
        // compact
        fm2.floatingCompact = true; pump(0.6)
        check(abs(fp.panel!.frame.width - FloatingPlayerController.windowSize(compact: true).width) < 1, "floating: the small version shrinks the window")
        fm2.floatingCompact = false; pump(0.6)
        check(abs(fp.panel!.frame.width - FloatingPlayerController.windowSize(compact: false).width) < 1, "floating: and goes back to full size")
        // three sizes: a double click steps small, medium, large and back to small
        fm2.floatingSize = .compact
        fm2.nextFloatingSize(); pump(0.6)
        check(fm2.floatingSize == .full && abs(fp.panel!.frame.width - FloatingPlayerController.windowSize(.full).width) < 1, "floating: a double click makes it medium")
        fm2.nextFloatingSize(); pump(0.8)
        check(fm2.floatingSize == .large && abs(fp.panel!.frame.height - FloatingPlayerController.windowSize(.large).height) < 1, "floating: the next one makes it large")
        for (n, sz) in [("small", NotchModel.FloatingSize.compact), ("medium", .full), ("large", .large)] {
            fm2.floatingSize = sz
            let r = ImageRenderer(content: FloatingPlayerView(model: fm2, close: {})
                .background(LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.55, green: 0.36, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            r.scale = 2
            if let img = r.cgImage { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: snapDir.appendingPathComponent("floating-\(n).png")) }
        }
        fm2.floatingSize = .large; pump(0.5)
        fm2.nextFloatingSize(); pump(0.6)
        check(fm2.floatingSize == .compact && abs(fp.panel!.frame.height - FloatingPlayerController.windowSize(.compact).height) < 1, "floating: the third goes back to small")
        fm2.defaults.removeObject(forKey: "floatingSize"); fm2.defaults.set(false, forKey: "floatingCompact")
        check(fm2.floatingSize == .full, "floating: a saved choice from before the third size is kept")
        fm2.floatingPlayerOn = false; pump(0.6)
        check(!fp.isShown, "floating: switched off, it goes")
        fm2.defaults.set(-9000.0, forKey: "floatingPlayerX")
        check(screen.insetBy(dx: -50, dy: -50).contains(fp.initialFrame()), "floating: a position from a screen that is gone is pulled back into view")
    }

    // shake strength presets
    func shakeWith(_ d0: ShakeDetector, amplitude: CGFloat) -> Bool {
        var d = d0
        var hit = false
        for i in 0..<100 {
            let t = Double(i) / 120
            if d.feed(x: 500 + amplitude * CGFloat(sin(Double(i) / 100.0 * 6 * .pi - .pi / 2)), at: t) { hit = true }
        }
        return hit
    }
    check(shakeWith(.preset(.easy), amplitude: 22) && !shakeWith(.preset(.normal), amplitude: 22), "shake: Easy catches a gentle shake that Normal ignores")
    check(shakeWith(.preset(.normal), amplitude: 35) && !shakeWith(.preset(.firm), amplitude: 35), "shake: Firm needs a bigger shake than Normal")
    check(shakeWith(.preset(.firm), amplitude: 60), "shake: Firm still works for a big shake")

    // shelf controls
    do {
        let cdir = askDir.appendingPathComponent("controls"); try? FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        UserDefaults(suiteName: "notchplus.tests.controls")!.removePersistentDomain(forName: "notchplus.tests.controls")
        let cm2 = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.controls")!), defaults: UserDefaults(suiteName: "notchplus.tests.controls")!,
                             shelf: ShelfStore(file: cdir.appendingPathComponent("shelf.json")))
        let cf = cdir.appendingPathComponent("keep.txt"); try! "x".write(to: cf, atomically: true, encoding: .utf8)
        _ = cm2.shelf.add([cf])
        let cid = cm2.shelf.items[0].id
        check(!cm2.shelfRemoveAfterDragOut && cm2.shelfKeepDays == 0 && cm2.shelfOpensOnDrag && cm2.basketShake == .normal, "controls: by default files stay, the shelf opens on a drag, and the shake is Normal")
        cm2.dragOutEnded(cid, droppedSomewhere: true)
        check(cm2.shelf.items.count == 1, "controls: with the option off, a dragged-out file stays on the shelf")
        cm2.shelfRemoveAfterDragOut = true
        cm2.dragOutEnded(cid, droppedSomewhere: false)
        check(cm2.shelf.items.count == 1, "controls: a cancelled drag never removes anything")
        cm2.dragOutEnded(cid, droppedSomewhere: true)
        check(cm2.shelf.items.isEmpty && FileManager.default.fileExists(atPath: cf.path), "controls: with the option on, a dropped file leaves the shelf, but the file itself is untouched")
        _ = cm2.shelf.add([cf])
        cm2.shelf.prune(olderThan: 86_400, now: Date().addingTimeInterval(12 * 3600))
        check(cm2.shelf.items.count == 1, "controls: a file younger than the limit is kept")
        cm2.shelf.prune(olderThan: 86_400, now: Date().addingTimeInterval(36 * 3600))
        check(cm2.shelf.items.isEmpty && FileManager.default.fileExists(atPath: cf.path), "controls: an older file is forgotten, and the file itself is untouched")
        _ = cm2.shelf.add([cf])
        cm2.shelfKeepDays = 0; cm2.pruneShelf(now: Date().addingTimeInterval(400 * 86_400))
        check(cm2.shelf.items.count == 1, "controls: with Until I remove them, nothing is ever forgotten")
        cm2.shelfOpensOnDrag = false; cm2.basketShake = .firm
        check(!cm2.shelfOpensOnDrag && cm2.basketShake == .firm, "controls: the choices are remembered")
    }

    do {
        let bdir = askDir.appendingPathComponent("basket"); try? FileManager.default.createDirectory(at: bdir, withIntermediateDirectories: true)
        UserDefaults(suiteName: "notchplus.tests.basket")!.removePersistentDomain(forName: "notchplus.tests.basket")
        let bm = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.basket")!), defaults: UserDefaults(suiteName: "notchplus.tests.basket")!,
                            shelf: ShelfStore(file: bdir.appendingPathComponent("shelf.json")))
        let fakeScreen = CGRect(x: -6000, y: 0, width: 1512, height: 900)
        let bc = BasketController(model: bm, visibleFrame: { fakeScreen })
        @MainActor func shakeIt(_ c: BasketController, from t0: Double) -> Bool {
            var hit = false
            for i in 0..<70 {
                let t = t0 + Double(i) / 120
                let x = -5200 + 90 * CGFloat(sin(Double(i) / 70.0 * 6 * .pi - .pi / 2))
                if c.dragMoved(to: CGPoint(x: x, y: 400), at: t) { hit = true }
            }
            return hit
        }
        check(bm.basketEnabled && bm.basketHideSeconds == 5, "basket: on by default, hides after 5 seconds")
        bm.basketEnabled = false
        check(!shakeIt(bc, from: 1) && !bc.shown, "basket: switched off in settings, shaking does nothing")
        bc.dragEnded()
        bm.basketEnabled = true
        check(shakeIt(bc, from: 100) && bc.shown, "basket: shaking while dragging files shows it")
        pump(0.2)
        check(bc.panel?.isVisible == true && fakeScreen.contains(bc.panel!.frame), "basket: its window is on the screen at the pointer")
        check(bc.panel?.canBecomeKey == false, "basket: it never takes the keyboard")
        // dropping puts files on the shelf
        let bf1 = bdir.appendingPathComponent("one.txt"); try! "1".write(to: bf1, atomically: true, encoding: .utf8)
        let bf2 = bdir.appendingPathComponent("two.txt"); try! "2".write(to: bf2, atomically: true, encoding: .utf8)
        check(bc.dropped([bf1]) && bm.basketStore.items.count == 1 && bm.shelf.items.isEmpty, "basket: a file dropped in stays in the basket, not on the shelf")
        check(bc.dropped([bf2]) && bm.basketStore.items.count == 2, "basket: more files can be dropped one after another")
        check(!bc.dropped([bf1]), "basket: the same file twice is not added again")
        // hiding
        bm.basketHideSeconds = 0.4
        bc.dragEnded()
        bc.hovering = true
        pump(0.9)
        check(bc.shown, "basket: while the pointer is over it, it stays")
        bc.hovering = false
        pump(1.0)
        check(!bc.shown, "basket: it hides by itself after the set time")
        pump(0.5)
        check(bc.panel?.isVisible == false, "basket: and its window goes away")
        check(bm.basketStore.items.count == 2, "basket: hiding keeps the files (they are still in the basket)")
        // shaking again brings the same files back
        check(shakeIt(bc, from: 200) && bc.shown, "basket: shaking again brings it back")
        bm.basketHideSeconds = 0
        bc.dragEnded()
        pump(1.0)
        check(bc.shown, "basket: with Never it stays until closed")
        bc.hide(); pump(0.5)
        check(!bc.shown && bc.panel?.isVisible == false, "basket: the close button closes it")
        bc.show(near: CGPoint(x: -5200, y: 400)); pump(0.7)
        if let v = bc.panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            let cs = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.20, green: 0.30, blue: 0.52, alpha: 1), CGColor(red: 0.55, green: 0.36, blue: 0.48, alpha: 1)] as CFArray, locations: [0, 1]),
               let cg = rep.cgImage {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(rep.pixelsHigh)), end: CGPoint(x: CGFloat(rep.pixelsWide), y: 0), options: [])
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: snapDir.appendingPathComponent("basket-with-files.png")) }
            }
        }
        bm.shelf.clear(); pump(0.3)
        if let v = bc.panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: snapDir.appendingPathComponent("basket-empty.png"))
        }
        bc.hide(); pump(0.5)
    }

    // the keyboard goes to the island only while a question box is open
    do {
        let km = NotchModel(rules: NotificationRules(defaults: UserDefaults(suiteName: "notchplus.tests.ask")!), defaults: UserDefaults(suiteName: "notchplus.tests.ask")!,
                            shelf: ShelfStore(file: askDir.appendingPathComponent("shelf.json")))
        _ = km.shelf.add([askText])
        let kc = NotchWindowController(model: km, geometry: .fake(notch: true), liveMouse: false, openSettings: {})
        pump(0.3)
        check(!kc.panel.canBecomeKey, "ask: normally the island never takes the keyboard")
        km.hovering = true; pump(0.2)
        km.startAsking(km.shelf.items[0]); pump(0.4)
        check(km.asking != nil && kc.panel.canBecomeKey, "ask: the question box lets you type")
        km.hovering = false; pump(0.4)
        check(km.asking == nil && !kc.panel.canBecomeKey, "ask: when the island closes the box closes and the keyboard goes back")
        km.hovering = true; pump(0.2)
        km.startAsking(km.shelf.items[0]); pump(0.2)
        km.stopAsking(); pump(0.2)
        check(!kc.panel.canBecomeKey && km.state == .overview, "ask: closing the box leaves the shelf open")
        let zip = askDir.appendingPathComponent("archive.zip"); try! Data([0x50, 0x4b]).write(to: zip)
        _ = km.shelf.add([zip])
        km.startAsking(km.shelf.items[0])
        check(km.asking == nil, "ask: a file of another kind has no question box")
        kc.panel.orderOut(nil)
    }

    // the waiting nudge
    do {
        let nd = UserDefaults(suiteName: "notchplus.tests.nudge")!
        nd.removePersistentDomain(forName: "notchplus.tests.nudge")
        let nm = NotchModel(rules: NotificationRules(defaults: nd), defaults: nd,
                            shelf: ShelfStore(file: askDir.appendingPathComponent("nudge-shelf.json")))
        let conn = HookConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
        let t0 = Date()
        check(nm.nudgeAfterMinutes == 3, "nudge: three minutes by default")
        check(!nm.isNudging(at: t0.addingTimeInterval(3600)), "nudge: nothing pending, nothing to remind")
        nm.handle(json: ["tool_name": "Bash", "session_id": "n1", "tool_input": ["command": "ls"], "cwd": "/tmp"], connection: conn)
        check(!nm.isNudging(at: t0.addingTimeInterval(120)), "nudge: two minutes is still fine")
        check(nm.isNudging(at: t0.addingTimeInterval(190)), "nudge: after three minutes Claude has waited long")
        nm.nudgePulse(at: t0.addingTimeInterval(190))
        check(nm.pulsing, "nudge: the island pulses")
        nm.pulsing = false
        nm.nudgePulse(at: t0.addingTimeInterval(200))
        check(!nm.pulsing, "nudge: not again within 30 seconds")
        nm.nudgePulse(at: t0.addingTimeInterval(230))
        check(nm.pulsing, "nudge: again after 30 seconds")
        nm.pulsing = false
        nm.nudgeAfterMinutes = 0
        check(!nm.isNudging(at: t0.addingTimeInterval(3600)), "nudge: the switch turns it off")
        nm.nudgeAfterMinutes = 99
        check(nm.nudgeAfterMinutes == 30, "nudge: at most 30 minutes")
        nm.nudgeAfterMinutes = 1
        nm.answer(allow: true)
        check(!nm.isNudging(at: t0.addingTimeInterval(3600)), "nudge: answering clears it")
        nm.macReturned()
        check(!nm.pulsing, "nudge: coming back with nothing waiting does nothing")
        // answered in the terminal: the hook stays open, but Claude reports the tool finished
        nm.handle(json: ["tool_name": "AskUserQuestion", "session_id": "n2", "tool_input": ["questions": [["question": "Q?", "header": "H", "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]]], "cwd": "/tmp"], connection: conn)
        nm.handleEvent(["hook_event_name": "PostToolUse", "session_id": "other", "tool_name": "AskUserQuestion"])
        check(nm.pending.count == 1, "terminal answer: another session's event leaves the card")
        nm.handleEvent(["hook_event_name": "PostToolUse", "session_id": "n2", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        check(nm.pending.count == 1, "terminal answer: another tool finishing leaves the card")
        nm.handleEvent(["hook_event_name": "PostToolUse", "session_id": "n2", "tool_name": "AskUserQuestion"])
        check(nm.pending.isEmpty, "terminal answer: the card closes when that tool finishes")
        nm.handle(json: ["tool_name": "Bash", "session_id": "n3", "tool_input": ["command": "ls"], "cwd": "/tmp"], connection: conn)
        nm.handleEvent(["hook_event_name": "Stop", "session_id": "n3"])
        check(nm.pending.isEmpty, "terminal answer: the card closes when the turn ends")
    }

    // lyrics and the song list from Music
    do {
        let raw = "[00:00.00] ...[00:24.62] Sometimes I need to remember just to breathe[00:30.11] [00:29.85] Sometimes I need you to stay away from me[00:34.93] [00:35.35] Sometimes I'm in disbelief, I didn't know\r[01:02.5] (Just give me myself back)"
        let lines = LyricsParser.parse(raw)
        check(lines.count == 5, "lyrics: empty stamps are dropped (got \(lines.count))")
        check(lines[1].time == 24.62 && lines[1].text == "Sometimes I need to remember just to breathe", "lyrics: a line keeps its time and words")
        check(lines.map { $0.time ?? 0 } == lines.map { $0.time ?? 0 }.sorted(), "lyrics: lines are in time order")
        check(LyricsParser.current(in: lines, at: 31) == 2, "lyrics: at 31 seconds the second line is sung")
        check(LyricsParser.current(in: lines, at: 0.0) == 0 && LyricsParser.current(in: lines, at: 500) == 4, "lyrics: first at the start, last at the end")
        let plain = LyricsParser.parse("one\ntwo\n\nthree")
        check(plain.count == 3 && plain.allSatisfy { $0.time == nil } && LyricsParser.current(in: plain, at: 20) == nil, "lyrics: plain words have no time and no sung line")
        check(LyricsParser.parse("").isEmpty, "lyrics: nothing gives nothing")
        let answer = "ABC2\nAAA1\tForeword\t13.5\tLinkin Park\tMeteora\nABC2\tDon't Stay\t188,2\tLinkin Park\tMeteora\nCCC3\tSomewhere I Belong\t214"
        let parsed = MusicLibrary.parseTracks(answer)
        check(parsed.currentID == "ABC2" && parsed.tracks.count == 3 && parsed.tracks[1].name == "Don't Stay" && abs(parsed.tracks[1].duration - 188.2) < 0.01, "song list: parsed with the playing song's id")
        check(parsed.tracks[1].artist == "Linkin Park" && parsed.tracks[1].album == "Meteora" && parsed.tracks[2].artist == "", "song list: artist and album come with each song when given")
        check(MusicLibrary.parseTracks("").tracks.isEmpty, "song list: an empty answer is no list")
        check(MusicControls.parse("true|false|off\n") == MusicControls(favorited: true, shuffle: false, repeatMode: .off), "controls: star, shuffle and repeat are read")
        check(MusicControls.parse("false|true|all")?.repeatMode == .all && MusicControls.parse("false|true|one")?.shuffle == true, "controls: repeat all and one")
        check(MusicControls.parse("") == nil && MusicControls.parse("true|false|sideways") == nil, "controls: an unclear answer shows no buttons")
        check(MusicControls.Repeat.off.next == .all && MusicControls.Repeat.all.next == .one && MusicControls.Repeat.one.next == .off, "controls: repeat goes off, all, one, off")
        let panelsView = ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.08, blue: 0.07), Color(red: 0.35, green: 0.2, blue: 0.1)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 0) {
                LyricsView(lines: lines, now: { 31 }, accent: .orange).frame(width: 300, height: 236)
                TrackListView(tracks: parsed.tracks, currentID: "ABC2", accent: .orange, isPlaying: false, cover: NSImage(size: NSSize(width: 40, height: 40), flipped: false) { r in NSColor.brown.setFill(); r.fill(); return true }) { _ in }.frame(width: 300, height: 236)
            }
        }.frame(width: 600, height: 236).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: panelsView)
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 236)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(CGPoint(x: -7000, y: 200)); win.orderFront(nil)
        pump(0.8)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: snapDir.appendingPathComponent("music-panels.png"))
        }
        win.orderOut(nil)
    }

    // song change peek and swipe to skip
    do {
        var sx = SwipeTracker()
        check(sx.feed(dx: -20, dy: 0, began: true, ended: false) == nil, "swipe skip: a short sideways movement does nothing")
        check(sx.feed(dx: -30, dy: 2, began: false, ended: false) == .left, "swipe skip: fingers left gives left")
        check(sx.feed(dx: -50, dy: 0, began: false, ended: false) == nil, "swipe skip: once per swipe")
        _ = sx.feed(dx: 0, dy: 0, began: false, ended: true)
        check(sx.feed(dx: 45, dy: 3, began: true, ended: false) == .right, "swipe skip: fingers right gives right")
        _ = sx.feed(dx: 0, dy: 0, began: false, ended: true)
        check(sx.feed(dx: -45, dy: 40, began: true, ended: false) != .left, "swipe skip: a slanted scroll never skips")
        var sv = SwipeTracker()
        check(sv.feed(dx: 3, dy: 20, began: true, ended: false) == .down, "swipe skip: a mostly vertical swipe still opens")
        let pd = UserDefaults(suiteName: "notchplus.tests.peek")!
        pd.removePersistentDomain(forName: "notchplus.tests.peek")
        let pm = NotchModel(rules: NotificationRules(defaults: pd), defaults: pd, shelf: ShelfStore(file: askDir.appendingPathComponent("peek-shelf.json")))
        func song(_ t: String, _ a: String = "Artist", playing: Bool = true) -> NowPlayingInfo {
            var n = playingInfo; n.title = t; n.artist = a; n.playing = playing; return n
        }
        pm.setNowPlaying(song("One"))
        check(pm.songPeek == nil, "peek: the first song shows no peek")
        pm.setNowPlaying(song("One"))
        check(pm.songPeek == nil, "peek: the same song again (a position update) shows none")
        pm.setNowPlaying(song("Two"))
        check(pm.songPeek == NotchModel.SongPeek(title: "Two", artist: "Artist"), "peek: a new song shows its name")
        check(pm.wingsWidth == 195, "peek: the wings open wider for it")
        pump(2.9)
        check(pm.songPeek == nil && pm.wingsWidth == 50, "peek: it goes away by itself")
        pm.showSongPeek = false
        pm.setNowPlaying(song("Three"))
        check(pm.songPeek == nil, "peek: switched off, no peek")
        pm.showSongPeek = true
        pm.setNowPlaying(song("Four", playing: false))
        check(pm.songPeek == nil, "peek: a paused change shows none")
        pm.setNowPlaying(nil); pm.setNowPlaying(song("Five"))
        check(pm.songPeek == nil, "peek: after nothing was playing it is a fresh start, no peek")
        var sent: [MediaCommand] = []
        pm.mediaSend = { sent.append($0) }
        pm.skipBySwipe(next: true)
        check(sent == [.next], "swipe skip: right is next")
        pm.skipBySwipe(next: false)
        check(sent == [.next], "swipe skip: a second skip within half a second is ignored")
        pm.rewindSwipeClockForTests()
        pm.skipBySwipe(next: false)
        check(sent == [.next, .previous], "swipe skip: left is previous")
        do {
            let pc = NotchWindowController(model: pm, geometry: .fake(notch: true), liveMouse: false, openSettings: {})
            pm.setNowPlaying(song("Easier To Run", "Linkin Park"))
            pm.setNowPlaying(song("Somewhere I Belong", "Linkin Park"))
            snapshot(pc, "song-peek", wait: 0.7)
            snapshot(pc, "song-peek-after", wait: 2.6)
            pc.panel.orderOut(nil)
        }
        pm.hovering = true; pm.rewindSwipeClockForTests(); pm.skipBySwipe(next: true)
        check(sent.count == 3, "swipe skip: it works on the open player too (pointing at the notch opens it)")
        pm.homeChoice = .shelf; pm.rewindSwipeClockForTests(); pm.skipBySwipe(next: true)
        check(sent.count == 3, "swipe skip: not on the shelf")
        pm.homeChoice = nil
        pm.hovering = false; pm.swipeSkips = false; pm.rewindSwipeClockForTests(); pm.skipBySwipe(next: true)
        check(sent.count == 3, "swipe skip: the switch turns it off")
    }

    do {   // the Translate menu shows a short list first
        let all = Translator.languages.map(\.id)
        let f = Translator.favourites(from: all, preferred: ["ar-US", "en-US"])
        check(f.prefix(2) == ["ar", "en"] && f.count == 6 && Set(f).count == 6, "translate menu: the Mac's own languages come first, six in all")
        check(Translator.favourites(from: all, preferred: []).first == "en" && Translator.favourites(from: ["fr", "de"], preferred: ["xx"]) == ["fr", "de"], "translate menu: English by default, only languages that exist")
        check(Translator.favourites(from: all, preferred: ["pt_BR"]).first == "pt", "translate menu: a region suffix is ignored")
    }

    do {   // the thin line over the cover picks dark or light from the cover's bottom edge
        func solid(_ c: NSColor) -> NSImage { NSImage(size: NSSize(width: 40, height: 40), flipped: false) { r in c.setFill(); r.fill(); return true } }
        check(ImageColor.bottomIsLight(of: solid(.white), key: "t-white"), "cover line: a white cover gets a dark line")
        check(!ImageColor.bottomIsLight(of: solid(.black), key: "t-black"), "cover line: a black cover gets a white line")
        let split = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { r in
            NSColor.black.setFill(); r.fill()                                  // dark on top
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 40, height: 12).fill()   // light along the bottom (not flipped: y 0 is the bottom)
            return true
        }
        check(ImageColor.bottomIsLight(of: split, key: "t-split"), "cover line: only the bottom edge decides")
    }

    do {   // a long answer from Ask must show whole
        let ld = UserDefaults(suiteName: "notchplus.tests.longask")!
        ld.removePersistentDomain(forName: "notchplus.tests.longask")
        let lm = NotchModel(rules: NotificationRules(defaults: ld), defaults: ld, shelf: ShelfStore(file: askDir.appendingPathComponent("longask-shelf.json")))
        _ = lm.shelf.add([askText])
        let lc = NotchWindowController(model: lm, geometry: .fake(notch: true), liveMouse: false, openSettings: {})
        lm.hovering = true; pump(0.3)
        lm.startAsking(lm.shelf.items[0])
        let longAnswer = "Upload Studio. Proof worked (Desktop/Upload Studio), but you said uploading by hand is better for checking, so it is not worth building a whole uploader right now. The next step would be to write the plan down, pick the three most useful checks, and run them against a real file before deciding anything else about the project."
        lm.asker(for: lm.shelf.items[0])?.engine = { _ in AsyncThrowingStream { c in c.yield(longAnswer); c.finish() } }
        lm.asker(for: lm.shelf.items[0])?.ask("whats first idea")
        pump(0.6)
        snapshot(lc, "ask-long", wait: 0.6)
        lc.panel.orderOut(nil)
    }

    do {   // Ask answers are never cut short
        let long = String(repeating: "A long answer about the file. ", count: 20)
        check(Intelligence.cleanAnswer(long).count == long.trimmingCharacters(in: .whitespaces).count, "ask: a long answer is not cut at 120 characters")
        check(Intelligence.cleanAnswer("**Bold** and `code`\n\nSecond paragraph") == "Bold and code\n\nSecond paragraph", "ask: paragraphs are kept, markup is removed")
        check(Intelligence.clean(long).count == 120 && Intelligence.clean(long).hasSuffix("..."), "summaries are still one short line")
    }

    do {   // Messages shown at once, from Messages' own database
        // the words inside a typed-stream blob
        var blob = Data([0x04, 0x0b]) + Data("streamtyped".utf8) + Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2b, 0x0b]) + Data("hello there".utf8) + Data([0x86])
        check(MessageText.extract(from: blob) == "hello there", "messages: words are read from the attributed body")
        let longText = String(repeating: "x", count: 300)
        blob = Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2b, 0x81, 0x2c, 0x01]) + Data(longText.utf8)
        check(MessageText.extract(from: blob) == longText, "messages: a long message uses the two byte length")
        check(MessageText.extract(from: Data([1, 2, 3])) == nil, "messages: a blob without words gives nothing")

        // contacts
        let cdir = askDir.appendingPathComponent("contacts"); try? FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let abPath = cdir.appendingPathComponent("AddressBook-v22.abcddb").path
        try? FileManager.default.removeItem(atPath: abPath)
        func run(_ db: OpaquePointer?, _ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
        var ab: OpaquePointer?
        sqlite3_open(abPath, &ab)
        run(ab, "CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZNICKNAME TEXT, ZORGANIZATION TEXT);")
        run(ab, "CREATE TABLE ZABCDPHONENUMBER (ZOWNER INTEGER, ZFULLNUMBER TEXT); CREATE TABLE ZABCDEMAILADDRESS (ZOWNER INTEGER, ZADDRESS TEXT);")
        run(ab, "INSERT INTO ZABCDRECORD VALUES (1, 'Mum', NULL, NULL, NULL), (2, 'Sam', 'Okafor', NULL, NULL), (3, NULL, NULL, NULL, 'Acme Ltd');")
        run(ab, "INSERT INTO ZABCDPHONENUMBER VALUES (1, '+44 7700 900123'), (3, '(555) 010-9999'); INSERT INTO ZABCDEMAILADDRESS VALUES (2, 'Sam@Example.com');")
        sqlite3_close(ab)
        let names = ContactNames(paths: { [abPath] })
        check(names.name(for: "+447700900123") == "Mum", "contacts: a phone number finds its name whatever the formatting")
        check(names.name(for: "sam@example.com") == "Sam Okafor", "contacts: an email finds its name, ignoring case")
        check(names.name(for: "5550109999") == "Acme Ltd", "contacts: a company name is used when there is no person name")
        check(names.name(for: "+15559998888") == nil && names.name(for: "12") == nil, "contacts: an unknown number has no name")

        // Messages' database
        let mpath = cdir.appendingPathComponent("chat.db").path
        for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: mpath + ext) }
        var md: OpaquePointer?
        sqlite3_open(mpath, &md)
        run(md, """
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER, is_from_me INTEGER, date_read INTEGER,
                                  associated_message_type INTEGER, item_type INTEGER, is_system_message INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER, display_name TEXT, chat_identifier TEXT, is_filtered INTEGER, is_blackholed INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            INSERT INTO handle VALUES (1, '+447700900123'), (2, 'stranger@example.com');
            INSERT INTO chat VALUES (1, 45, '', '+447700900123', 0, 0), (2, 45, '', 'stranger@example.com', 1, 0), (3, 43, 'Family', 'chat123', 0, 0);
            INSERT INTO message VALUES (1, 'OLD', 'before we started', NULL, 1, 0, 0, 0, 0, 0);
            INSERT INTO chat_message_join VALUES (1, 1);
            """)
        let watcher = MessagesWatcher(path: mpath, contacts: names)
        check(watcher.open() && watcher.lastRowID == 1, "messages: it starts after the newest message")
        check(watcher.readNew().isEmpty, "messages: nothing new, nothing shown")
        run(md, """
            INSERT INTO message VALUES (2, 'G2', 'Dinner at 8?', NULL, 1, 0, 0, 0, 0, 0);
            INSERT INTO chat_message_join VALUES (1, 2);
            INSERT INTO message VALUES (3, 'G3', 'my own', NULL, 1, 1, 0, 0, 0, 0);
            INSERT INTO chat_message_join VALUES (1, 3);
            INSERT INTO message VALUES (4, 'G4', 'Loved "Dinner at 8?"', NULL, 1, 0, 0, 2000, 0, 0);
            INSERT INTO chat_message_join VALUES (1, 4);
            INSERT INTO message VALUES (5, 'G5', 'already read elsewhere', NULL, 1, 0, 777, 0, 0, 0);
            INSERT INTO chat_message_join VALUES (1, 5);
            INSERT INTO message VALUES (6, 'G6', 'unknown sender', NULL, 2, 0, 0, 0, 0, 0);
            INSERT INTO chat_message_join VALUES (2, 6);
            INSERT INTO message VALUES (7, 'G7', 'Pizza?', NULL, 1, 0, 0, 0, 0, 0);
            INSERT INTO chat_message_join VALUES (3, 7);
            """)
        let got = watcher.readNew()
        check(got.count == 2 && got[0].body == "Dinner at 8?" && got[1].body == "Pizza?", "messages: only real, unread, wanted messages are shown (not mine, reactions, read, filtered)")
        check(got[0].title == "Mum" && got[0].guid == "G2" && got[0].thread == "any;-;+447700900123" && got[0].bundleID == "com.apple.MobileSMS", "messages: it says who, carries the id, and can be replied to")
        check(got[1].thread == nil && got[1].subtitle == "Family", "messages: a group message names the group and has no quick reply")
        check(watcher.lastRowID == 7 && watcher.readNew().isEmpty, "messages: each message is shown once")
        // a message whose conversation is not stored yet is waited for
        run(md, "INSERT INTO message VALUES (8, 'G8', 'late join', NULL, 1, 0, 0, 0, 0, 0);")
        let t0 = Date()
        check(watcher.readNew(now: t0).isEmpty && watcher.lastRowID == 7, "messages: it waits for the conversation to be stored")
        run(md, "INSERT INTO chat_message_join VALUES (1, 8);")
        check(watcher.readNew(now: t0.addingTimeInterval(1)).first?.body == "late join", "messages: and shows it as soon as it is")
        // one that never gets a conversation is dropped after a few seconds, and does not block the next
        run(md, "INSERT INTO message VALUES (9, 'G9', 'orphan', NULL, 1, 0, 0, 0, 0, 0);")
        let t1 = Date()
        check(watcher.readNew(now: t1).isEmpty, "messages: an orphan is waited for")
        run(md, "INSERT INTO message VALUES (10, 'G10', 'after the orphan', NULL, 1, 0, 0, 0, 0, 0); INSERT INTO chat_message_join VALUES (1, 10);")
        check(watcher.readNew(now: t1.addingTimeInterval(7)).map(\.body) == ["after the orphan"], "messages: after a few seconds the orphan is dropped and the next one shows")
        sqlite3_close(md)

        // the same message from the database and from macOS's notification record: shown once
        let gd = UserDefaults(suiteName: "notchplus.tests.guid")!
        gd.removePersistentDomain(forName: "notchplus.tests.guid")
        let gm = NotchModel(rules: NotificationRules(defaults: gd), defaults: gd, shelf: ShelfStore(file: cdir.appendingPathComponent("guid-shelf.json")))
        gm.respectFocus = false
        check(gm.instantMessages, "messages: shown at once by default")
        gm.receive([RawNotification(recordID: -2, bundleID: "com.apple.MobileSMS", title: "Mum", subtitle: nil, body: "Dinner at 8?", date: Date(), thread: "any;-;+447700900123", guid: "G2")])
        gm.receive([RawNotification(recordID: 901, bundleID: "com.apple.mobilesms", title: "Mum", subtitle: nil, body: "Dinner at 8?", date: Date(), thread: "any;-;+447700900123", guid: "G2")])
        check(gm.notifications.count == 1, "messages: the late macOS record of the same message is skipped")
        gm.receive([RawNotification(recordID: 902, bundleID: "com.apple.mobilesms", title: "Mum", subtitle: nil, body: "Dinner at 8?", date: Date(), thread: nil, guid: nil)])
        check(gm.notifications.count == 2, "messages: notifications without an id are never skipped")
    }

    print("")
    print("\(passes) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
