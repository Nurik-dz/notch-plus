import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    let installer: HookInstaller
    let notch: NotchModel
    let notifications: NotificationController
    @Published var confirming = false
    @Published var message: String?
    @Published var apps: [(id: String, name: String)] = []
    @Published var loginState = LoginItem.state
    @Published var loginMessage: String?

    func setLogin(_ on: Bool) {
        do { try LoginItem.set(on); loginMessage = nil }
        catch { loginMessage = on ? "macOS would not let Notch+ open at login (\(error.localizedDescription)). Move Notch+ to the Applications folder and try again." : error.localizedDescription }
        loginState = LoginItem.state
    }

    init(installer: HookInstaller, notch: NotchModel, notifications: NotificationController) {
        self.installer = installer
        self.notch = notch
        self.notifications = notifications
        refresh()
    }

    func refresh() {
        notch.hookStatus = installer.status()
        loginState = LoginItem.state
        notifications.start()
        // every app that can send notifications, plus any seen ones the system list does not have
        var all: [String: String] = [:]
        for a in notifications.registeredApps() { all[a.id.lowercased()] = a.name }
        for (id, name) in notch.rules.seenApps where all[id.lowercased()] == nil { all[id.lowercased()] = name }
        apps = all.map { (id: $0.key, name: $0.value) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func mode(for id: String) -> NotificationMode { notch.rules.mode(for: id) }
    func setMode(_ m: NotificationMode, for id: String) {
        notch.rules.set(m, for: id)
        objectWillChange.send()
    }

    func connect() {
        do {
            let backedUp = try installer.connect()
            message = backedUp ? "Connected. A backup of your old settings was saved next to the file."
                               : "Connected."
        } catch {
            message = error.localizedDescription
        }
        confirming = false
        refresh()
    }

    func disconnect() {
        do {
            try installer.disconnect()
            message = "Disconnected. Only Notch+'s own entry was removed."
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var notch: NotchModel

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            claudeCode.tabItem { Label("Claude Code", systemImage: "terminal") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
            shelfAndBasket.tabItem { Label("Shelf and Basket", systemImage: "tray") }
        }
        .frame(width: 560, height: 520)
        .sheet(isPresented: $settings.confirming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect Claude Code").font(.title2.bold())
                Text("Notch+ will add this to \(settings.installer.paths.claudeSettings.path). A backup of the existing file is saved first. Nothing else in the file changes.")
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(settings.installer.previewText())
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                HStack {
                    Spacer()
                    Button("Cancel") { settings.confirming = false }
                    Button("Connect") { settings.connect() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 520, height: 340)
        }
    }

    // MARK: - Tabs

    private var general: some View {
        Form {
            SwiftUI.Section {
                Toggle("Open Notch+ when I log in", isOn: Binding(
                    get: { settings.loginState == .on || settings.loginState == .needsApproval },
                    set: { settings.setLogin($0) }))
                if settings.loginState == .needsApproval {
                    HStack {
                        note("Allow Notch+ in System Settings > General > Login Items.")
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                } else if !Bundle.main.bundlePath.hasPrefix("/Applications") {
                    note("Tip: keep Notch+ in the Applications folder so this keeps working if the app is ever moved.")
                }
                if let m = settings.loginMessage { Text(m).font(.callout).foregroundStyle(.orange) }
            } header: { Text("Startup") }

            SwiftUI.Section {
                Picker("Island", selection: Binding(get: { notch.islandStyle }, set: { notch.islandStyle = $0 })) {
                    ForEach(NotchModel.IslandStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Edge glow", selection: Binding(get: { notch.glowLevel }, set: { notch.glowLevel = $0 })) {
                    ForEach(NotchModel.GlowLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { Text("Look") }

            SwiftUI.Section {
                Toggle("Music while it plays", isOn: Binding(
                    get: { notch.showMusicBesideNotch }, set: { notch.showMusicBesideNotch = $0 }))
                Toggle("Show the song name when the song changes", isOn: Binding(
                    get: { notch.showSongPeek }, set: { notch.showSongPeek = $0 }))
                Toggle("Swipe left or right on the notch to skip songs", isOn: Binding(
                    get: { notch.swipeSkips }, set: { notch.swipeSkips = $0 }))
                Toggle("Volume and brightness", isOn: Binding(
                    get: { notch.showLevels }, set: { notch.showLevels = $0 }))
            } header: { Text("Show beside the notch") }

            SwiftUI.Section {
                note("Point at the notch to open the player or the shelf. Drag the player down to float it above your windows, and back up to put it away.")
            } header: { Text("Tip") }
        }
        .formStyle(.grouped)
    }

    private var claudeCode: some View {
        Form {
            SwiftUI.Section {
                HStack {
                    statusLabel
                    Spacer()
                    switch notch.hookStatus {
                    case .connected:
                        Button("Disconnect") { settings.disconnect() }
                    case .outdated:
                        Button("Update…") { settings.confirming = true }
                            .buttonStyle(.borderedProminent)
                    default:
                        Button("Connect Claude Code…") { settings.confirming = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                note("Claude Code asks Notch+ before it asks you. If Notch+ is not running, Claude Code asks in the terminal as usual, so it never gets stuck.")
                if let m = settings.message { Text(m).font(.callout) }
                Toggle("Remind me when Claude has waited", isOn: Binding(
                    get: { notch.nudgeAfterMinutes > 0 }, set: { notch.nudgeAfterMinutes = $0 ? 3 : 0 }))
                if notch.nudgeAfterMinutes > 0 {
                    Stepper("After \(notch.nudgeAfterMinutes) min", value: Binding(
                        get: { notch.nudgeAfterMinutes }, set: { notch.nudgeAfterMinutes = $0 }), in: 1...30)
                    note("The timer turns amber and the island glows brighter now and then. Nothing is hidden or delayed.")
                }
            } header: { Text("Approvals") }

            SwiftUI.Section {
                Button("Check Again") { settings.refresh() }
            }
        }
        .formStyle(.grouped)
    }

    private var notifications: some View {
        Form {
            SwiftUI.Section {
                HStack {
                    notificationStatus
                    Spacer()
                    if notch.notificationAccess == .needsFullDiskAccess {
                        Button("Give Full Disk Access…") {
                            AccessGuide.shared.showFullDiskAccess { [weak notch] in notch?.notificationAccess == .granted }
                        }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Picker("Cards show", selection: Binding(get: { notch.notificationText }, set: { notch.notificationText = $0 })) {
                    ForEach(NotchModel.NotificationText.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!Intelligence.isAvailable)
                Toggle("Label with Apple Intelligence (Needs you, Quiet)", isOn: Binding(
                    get: { notch.sortWithAppleIntelligence }, set: { notch.sortWithAppleIntelligence = $0 }))
                    .disabled(!Intelligence.isAvailable)
                note(Intelligence.isAvailable
                     ? "Your choice. Apple Intelligence runs on this Mac, privately, and never hides a notification: the card opens at once with the full message, and a summary or label is added a moment later only if you switch it on."
                     : "Apple Intelligence is not available on this Mac right now, so cards show the full message.")
                Toggle("Show Messages the moment they arrive", isOn: Binding(
                    get: { notch.instantMessages }, set: { notch.instantMessages = $0 }))
                note("macOS hands over a message notification 8 to 13 seconds late. With this on, Notch+ reads the message from Messages itself, about a second after it arrives.")
                Toggle("Reply to Messages from the notch", isOn: Binding(
                    get: { notch.messagesReplyOn }, set: { notch.messagesReplyOn = $0 }))
                note("A Reply button on Messages cards from one person (not group chats). Nothing is sent until you press Send. The first time, macOS asks to let Notch+ use Messages.")
                Toggle("Keep quiet while a Focus is on", isOn: Binding(
                    get: { notch.respectFocus }, set: { notch.respectFocus = $0 }))
            } header: { Text("Notch+ reads your notifications") }

            SwiftUI.Section {
                if settings.apps.isEmpty {
                    Text("No apps yet. They appear here after their first notification.").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.apps, id: \.id) { app in
                        HStack {
                            AppIconView(bundleID: app.id, size: 20)
                            Text(app.name)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { settings.mode(for: app.id) },
                                set: { settings.setMode($0, for: app.id) })) {
                                ForEach(NotificationMode.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                    }
                }
            } header: { Text("What each app may do") }
        }
        .formStyle(.grouped)
    }

    private var shelfAndBasket: some View {
        Form {
            SwiftUI.Section {
                Toggle("Open the shelf when I drag files toward the notch", isOn: Binding(
                    get: { notch.shelfOpensOnDrag }, set: { notch.shelfOpensOnDrag = $0 }))
                Toggle("Take a file off the shelf after I drag it out", isOn: Binding(
                    get: { notch.shelfRemoveAfterDragOut }, set: { notch.shelfRemoveAfterDragOut = $0 }))
                Picker("Keep files on the shelf", selection: Binding(get: { notch.shelfKeepDays }, set: { notch.shelfKeepDays = $0 })) {
                    Text("Until I remove them").tag(0); Text("1 day").tag(1); Text("1 week").tag(7); Text("1 month").tag(30)
                }
                note("The shelf only keeps links. Your files are never copied, moved or deleted.")
            } header: { Text("Notch shelf") }

            SwiftUI.Section {
                Toggle("Show a basket when I shake the mouse while dragging", isOn: Binding(
                    get: { notch.basketEnabled }, set: { notch.basketEnabled = $0 }))
                Toggle("Files in the basket also go to the shelf", isOn: Binding(
                    get: { notch.basketSendsToShelf }, set: { notch.basketSendsToShelf = $0 }))
                    .disabled(!notch.basketEnabled)
                note(notch.basketSendsToShelf
                     ? "The basket and the shelf show the same files."
                     : "The basket keeps its own files. Press To shelf in the basket to move some across.")
                Picker("Shake", selection: Binding(get: { notch.basketShake }, set: { notch.basketShake = $0 })) {
                    ForEach(ShakeDetector.Strength.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).disabled(!notch.basketEnabled)
                Picker("Hide the basket", selection: Binding(get: { notch.basketHideSeconds }, set: { notch.basketHideSeconds = $0 })) {
                    Text("After 3 seconds").tag(3.0); Text("After 6").tag(6.0); Text("After 15").tag(15.0); Text("Never").tag(0.0)
                }
                .pickerStyle(.segmented).disabled(!notch.basketEnabled)
            } header: { Text("Floating basket") }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusLabel: some View {
        switch notch.hookStatus {
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notConnected:
            Label("Not connected", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .outdated:
            Label("Connected (update available)", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .problem(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var notificationStatus: some View {
        switch notch.notificationAccess {
        case .granted:
            Label("Reading notifications", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsFullDiskAccess:
            Label("Needs Full Disk Access", systemImage: "lock.fill").foregroundStyle(.orange)
        case .unknown:
            Label("Checking…", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
