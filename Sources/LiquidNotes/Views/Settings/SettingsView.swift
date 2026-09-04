import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var server: NoteServer
    @ObservedObject var vaultManager: VaultManager

    var body: some View {
        TabView {
            GeneralSettingsView(store: settingsStore)
                .tabItem { Label("General", systemImage: "gearshape") }
            IndexSettingsView(vaultManager: vaultManager, indexer: vaultManager.indexer)
                .tabItem { Label("Indexing", systemImage: "magnifyingglass") }
            ServerSettingsView(store: settingsStore, server: server)
                .tabItem { Label("Web Server", systemImage: "globe") }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .preferredColorScheme(settingsStore.settings.appearance.preferredColorScheme)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Appearance") {
                AppearancePicker(appearance: $store.settings.appearance)
                Text(store.settings.appearance.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Show in menu bar", isOn: $store.settings.menuBarMode)
                Text("Shows a LiquidNotes extra in the menu bar. Closing the last window keeps the app running there instead of quitting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { newValue in
                        do {
                            try store.setLaunchAtLogin(newValue)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                ))
                Text("Starts LiquidNotes automatically when you log in to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ServerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var server: NoteServer
    @State private var portText: String = ""
    @FocusState private var portFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Run web server", isOn: Binding(
                    get: { store.settings.serverEnabled },
                    set: { on in
                        commitPort(restart: false)
                        store.settings.serverEnabled = on
                        if on {
                            server.start(port: store.settings.serverPort, localhostOnly: store.settings.serverLocalhostOnly)
                        } else {
                            server.stop()
                        }
                    }
                ))
                Toggle("Start server when LiquidNotes opens", isOn: $store.settings.serverAutoStart)
                Text("While the server is on, LiquidNotes stays in the menu bar so phones can keep connecting. Closing the window hides the Dock icon until you open LiquidNotes again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Listen") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 80)
                        .focused($portFocused)
                        .onSubmit { commitPort(restart: true) }
                }
                Picker("Address", selection: $store.settings.serverLocalhostOnly) {
                    Text("This Mac only (localhost)").tag(true)
                    Text("Local network").tag(false)
                }
                .onChange(of: store.settings.serverLocalhostOnly) { _, _ in
                    restartIfNeeded()
                }
                Text(store.settings.serverLocalhostOnly
                     ? "Only apps on this Mac can open the web app."
                     : "Phones and other computers on your Wi-Fi can open the web app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                HStack {
                    Circle()
                        .fill(server.isRunning ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(server.isRunning ? "Running at \(server.listenURL)" : "Stopped")
                        .textSelection(.enabled)
                    Spacer()
                }
                if let error = server.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !store.settings.serverLocalhostOnly, let ip = NoteServer.lanIPv4() {
                    Text("On this network: http://\(ip):\(store.settings.serverPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open in Browser") {
                        if let url = URL(string: server.listenURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .disabled(!server.isRunning)
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(server.listenURL, forType: .string)
                    }
                    .disabled(!server.isRunning)
                    Spacer()
                    Button(server.isRunning ? "Restart" : "Start") {
                        commitPort(restart: false)
                        store.settings.serverEnabled = true
                        server.start(port: store.settings.serverPort, localhostOnly: store.settings.serverLocalhostOnly)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { portText = String(store.settings.serverPort) }
        .onChange(of: portText) { _, newValue in
            let digits = newValue.filter(\.isNumber)
            if digits != newValue {
                portText = digits
            }
            if let port = Int(digits), (1...65_535).contains(port) {
                store.settings.serverPort = port
            }
        }
        .onChange(of: portFocused) { _, focused in
            if !focused { commitPort(restart: true) }
        }
        .onChange(of: store.settings.serverPort) { _, port in
            if !portFocused {
                portText = String(port)
            }
        }
    }

    private func commitPort(restart: Bool) {
        let digits = portText.filter(\.isNumber)
        if let port = Int(digits), (1...65_535).contains(port) {
            store.settings.serverPort = port
            portText = String(port)
            if restart { restartIfNeeded() }
        } else {
            portText = String(store.settings.serverPort)
        }
    }

    private func restartIfNeeded() {
        if store.settings.serverEnabled {
            server.start(port: store.settings.serverPort, localhostOnly: store.settings.serverLocalhostOnly)
        }
    }
}

struct AppearancePicker: View {
    @Binding var appearance: AppAppearance

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppAppearance.allCases) { option in
                Button {
                    appearance = option
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.iconName)
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .frame(height: 22)
                        Text(option.title)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(appearance == option ? Color.accentColor : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appearance == option ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                appearance == option ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: appearance == option ? 1.5 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(appearance == option ? .isSelected : [])
            }
        }
    }
}

struct IndexSettingsView: View {
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var indexer: IndexCoordinator
    /// Drives the estimate and elapsed readouts while a rebuild is running.
    @State private var now = Date()
    @State private var footprint = LiquidNotesMemory.footprint()

    private static let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Status") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Vault").foregroundStyle(.secondary)
                        Text(vaultManager.activeVault?.name ?? "None")
                            .gridColumnAlignment(.leading)
                    }
                    GridRow {
                        Text("State").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(indexer.status.isRunning ? Color.accentColor : Color.green)
                                .frame(width: 8, height: 8)
                            Text(indexer.status.isRunning ? indexer.status.phase.label : "Up to date")
                        }
                    }
                    GridRow {
                        Text("Files").foregroundStyle(.secondary)
                        Text(filesText).monospacedDigit()
                    }
                    GridRow {
                        Text("Progress").foregroundStyle(.secondary)
                        Text("\(indexer.status.isRunning ? indexer.status.percent : 100)%").monospacedDigit()
                    }
                    GridRow {
                        Text("Time remaining").foregroundStyle(.secondary)
                        Text(remainingText).monospacedDigit()
                    }
                    GridRow {
                        Text("Last rebuild").foregroundStyle(.secondary)
                        Text(lastRebuildText).monospacedDigit()
                    }
                }
                .font(.callout)

                ProgressView(value: indexer.status.isRunning ? indexer.status.fraction : 1)
                    .progressViewStyle(.linear)
                    .tint(indexer.status.isRunning ? Color.accentColor : Color.green)
            }

            Section("Index contents") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Notes indexed").foregroundStyle(.secondary)
                        Text(indexer.indexedNotes.formatted()).monospacedDigit()
                    }
                    GridRow {
                        Text("Attachments tracked").foregroundStyle(.secondary)
                        Text(indexer.attachmentCount.formatted()).monospacedDigit()
                    }
                    GridRow {
                        Text("Distinct words").foregroundStyle(.secondary)
                        Text(indexer.searchStats.tokens.formatted()).monospacedDigit()
                    }
                    GridRow {
                        Text("Postings").foregroundStyle(.secondary)
                        Text(indexer.searchStats.postings.formatted()).monospacedDigit()
                    }
                    GridRow {
                        Text("Note text scanned").foregroundStyle(.secondary)
                        Text(Self.bytes(indexer.corpusBytes)).monospacedDigit()
                    }
                    GridRow {
                        Text("Index memory").foregroundStyle(.secondary)
                        Text(Self.bytes(indexer.approximateBytes)).monospacedDigit()
                    }
                    GridRow {
                        Text("App footprint").foregroundStyle(.secondary)
                        Text(Self.bytes(footprint)).monospacedDigit()
                    }
                }
                .font(.callout)
            }

            Section {
                HStack {
                    Button("Rebuild Index") {
                        vaultManager.rebuildIndex()
                    }
                    .disabled(indexer.status.isRunning || vaultManager.activeVault == nil)
                    if indexer.status.isRunning {
                        Button("Cancel") { indexer.cancel() }
                    }
                    Spacer()
                    Button("Release Memory") {
                        LiquidNotesMemory.releaseIdle()
                        indexer.refreshStats()
                        footprint = LiquidNotesMemory.footprint()
                    }
                }
                Text("Notes are re-indexed as you edit them. A full rebuild is only needed if files changed outside LiquidNotes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { footprint = LiquidNotesMemory.footprint() }
        .onReceive(Self.timer) { date in
            if indexer.status.isRunning { now = date }
            footprint = LiquidNotesMemory.footprint()
        }
    }

    private var filesText: String {
        let s = indexer.status
        guard s.filesTotal > 0 else { return "—" }
        return "\(s.filesDone.formatted()) / \(s.filesTotal.formatted())"
    }

    private var remainingText: String {
        guard indexer.status.isRunning else { return "—" }
        _ = now
        guard let remaining = indexer.status.estimatedRemaining else { return "Estimating…" }
        return remaining < 1 ? "Less than a second" : Self.duration(remaining)
    }

    private var lastRebuildText: String {
        let s = indexer.status
        guard let finished = s.finishedAt, s.lastDuration > 0 else { return "—" }
        return "\(Self.duration(s.lastDuration)) · \(finished.formatted(date: .omitted, time: .shortened))"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    private static func bytes(_ count: Int) -> String {
        guard count > 0 else { return "—" }
        let mb = Double(count) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", mb)
    }
}
