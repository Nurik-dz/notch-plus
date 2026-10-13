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
        apps = notch.rules.seenApps.map { (id: $0.key, name: $0.value) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
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
                Picker("Edge glow", selection: Binding(get: { notch.glowLevel }, set: { notch.glowLevel = $0 })) {
                    ForEach(NotchModel.GlowLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { Text("Look") }

            SwiftUI.Section {
                Toggle("Music while it plays", isOn: Binding(
                    get: { notch.showMusicBesideNotch }, set: { notch.showMusicBesideNotch = $0 }))
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
                        Button("Open Full Disk Access…") { NotificationController.openFullDiskAccessSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Toggle("Sort with Apple Intelligence", isOn: Binding(
                    get: { notch.sortWithAppleIntelligence }, set: { notch.sortWithAppleIntelligence = $0 }))
                note(Intelligence.isAvailable
                     ? "On this Mac, privately. It marks what needs you now and keeps noise out of the notch."
                     : "Apple Intelligence is not available on this Mac right now, so every notification is shown by the rules below.")
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
