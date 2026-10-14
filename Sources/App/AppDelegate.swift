import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths = AppPaths()
    let model = NotchModel()
    var server: HookServer!
    var windowController: NotchWindowController!
    var settingsModel: SettingsModel!
    var notificationController: NotificationController!
    var nowPlaying: NowPlayingController!
    var levels: SystemLevels!
    var basket: BasketController!
    var floatingPlayer: FloatingPlayerController!
    var power: PowerWatcher!
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem!
    var awakeItem: NSMenuItem?
    var floatingItem: NSMenuItem?
    var desktopItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apple Intelligence and Focus, on this Mac only.
        model.triage = { raw in await Intelligence.triage(raw, appName: AppLookup.name(for: raw.bundleID)) }
        model.explain = { r in await Intelligence.explain(tool: r.tool, headline: r.headline, detail: r.detail) }
        model.focusIsOn = { FocusState.isOn() }
        model.sendMessage = { text, handle in try await MessagesReply.send(text, to: handle) }
        model.suggestReplies = { n, handle in
            let mine = await Task.detached { MessagesReply.recentSent(to: handle) }.value
            return await Intelligence.suggestReplies(to: n.raw.body ?? n.headline, from: n.headline, myEarlier: mine)
        }
        model.startClock()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.macReturned() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.macReturned() }
        }

        // What is playing, and the controls for it.
        nowPlaying = NowPlayingController.bundled()
        nowPlaying.onChange = { [weak self] info in self?.model.setNowPlaying(info) }
        model.mediaSend = { [weak self] c in self?.nowPlaying.send(c) }
        model.mediaSeek = { [weak self] s in self?.nowPlaying.seek(to: s) }
        nowPlaying.start()

        // Volume and brightness, shown beside the notch.
        levels = SystemLevels()
        levels.onChange = { [weak self] r in self?.model.showHUD(r) }
        levels.start()
        power = PowerWatcher()
        power.onEvent = { [weak self] e in self?.model.showPower(e) }
        power.start()

        notificationController = NotificationController(model: model)
        HookInstaller(paths: paths).refreshScriptIfConnected()     // older installs get the current hook script
        settingsModel = SettingsModel(installer: HookInstaller(paths: paths), notch: model, notifications: notificationController)

        windowController = NotchWindowController(model: model, geometry: .current()) { [weak self] in
            self?.showSettings()
        }

        floatingPlayer = FloatingPlayerController(model: model)
        floatingPlayer.start()
        basket = BasketController(model: model)
        windowController.onFileDrag = { [weak self] p in self?.basket.dragMoved(to: p) }
        windowController.onDragEnd = { [weak self] in self?.basket.dragEnded() }

        server = HookServer(token: TokenStore.load(paths))
        server.onRequest = { [weak self] json, connection in self?.model.handle(json: json, connection: connection) }
        server.onEvent = { [weak self] json in self?.model.handleEvent(json) }
        server.onFailure = { [weak self] message in self?.model.serverProblem = message }
        do { try server.start() } catch { model.serverProblem = "Notch+ could not listen for Claude Code: \(error.localizedDescription)" }

        // Keyboard answers exist only while a request is waiting.
        let keys = HotKeys.shared
        keys.onAllow = { [weak self] in self?.model.answer(allow: true) }
        keys.onDeny = { [weak self] in self?.model.answer(allow: false) }
        keys.onAlways = { [weak self] in self?.model.answer(allow: true, always: true) }
        model.$pending.receive(on: RunLoop.main).sink { pending in
            if pending.isEmpty { keys.disable() } else { keys.enable() }
        }.store(in: &cancellables)


        buildStatusItem()
        watchCaffeine()
        if DemoMode.isOn { DemoMode.start(model: model) }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "Notch+")
        let menu = NSMenu()
        let awake = menu.addItem(withTitle: "Keep Mac Awake", action: #selector(toggleAwake), keyEquivalent: "")
        awake.target = self
        awakeItem = awake
        let floating = menu.addItem(withTitle: "Floating Player", action: #selector(toggleFloatingPlayer), keyEquivalent: "")
        floating.target = self
        floatingItem = floating
        let desktop = menu.addItem(withTitle: "Hide Desktop Items", action: #selector(toggleDesktop), keyEquivalent: "")
        desktop.target = self
        desktopItem = desktop
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notch+", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openSettings() { showSettings() }
    @objc private func toggleFloatingPlayer() { model.floatingPlayerOn.toggle() }
    @objc private func toggleDesktop() { model.setDesktopHidden(!model.desktopHidden) }
    @objc private func toggleAwake() { model.setCaffeine(model.caffeine.active ? nil : .untilOff) }

    /// The menu bar icon becomes a cup while the Mac is being kept awake, so it is never forgotten.
    private func watchCaffeine() {
        model.caffeine.$active.receive(on: RunLoop.main).sink { [weak self] on in
            self?.statusItem.button?.image = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "capsule.tophalf.filled",
                                                     accessibilityDescription: on ? "Notch+ (keeping the Mac awake)" : "Notch+")
            self?.awakeItem?.state = on ? .on : .off
        }.store(in: &cancellables)
        model.$desktopHidden.receive(on: RunLoop.main).sink { [weak self] hidden in
            self?.desktopItem?.state = hidden ? .on : .off
        }.store(in: &cancellables)
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.floatingItem?.state = (self?.model.floatingPlayerOn ?? false) ? .on : .off        }.store(in: &cancellables)
    }

    func showSettings() {
        settingsModel.refresh()
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settingsModel, notch: model)))
            w.title = "Notch+ Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
