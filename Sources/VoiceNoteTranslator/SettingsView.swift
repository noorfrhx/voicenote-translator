import AppKit
import Combine
import SwiftUI
import VNTCore

enum SettingsTab: String, CaseIterable {
    case general, translation, connections, history, about
}

struct SettingsView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            TranslationTab().tabItem { Label("Translation", systemImage: "character.bubble") }.tag(SettingsTab.translation)
            ConnectionsTab().tabItem { Label("Connections", systemImage: "point.3.connected.trianglepath.dotted") }.tag(SettingsTab.connections)
            HistoryTab().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(SettingsTab.history)
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 440)
    }
}

// MARK: - General

private let commonLanguages = ["English", "German", "Arabic", "French", "Spanish", "Italian", "Portuguese", "Turkish",
                               "Russian", "Urdu", "Hindi", "Chinese", "Japanese", "Dutch", "Polish"]

struct GeneralTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var history = TranslationService.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Translate into", selection: $settings.targetLanguage) {
                    ForEach(languageOptions, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or type a language", text: $settings.targetLanguage)
                    .help("Any language the model knows, e.g. \"Swiss German\" or \"Simple English\".")
            }
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .help("Starts VoiceNote Translator in the menu bar when you log in, so WhatsApp Web and Desktop work right after a restart.")
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LaunchAtLogin.set(on); loginError = nil }
                        catch { loginError = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show Translate buttons in WhatsApp Desktop", isOn: $settings.desktopButtons)
            }
            Section {
                Toggle("Remember translations", isOn: $settings.rememberTranslations)
                    .onChange(of: settings.rememberTranslations) { _, _ in history.save() }
                Text("Keeps finished translations on this Mac so a voice note is only sent to the API once. Turn off to keep them in memory only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var languageOptions: [String] {
        commonLanguages.contains(settings.targetLanguage) || settings.targetLanguage.isEmpty
            ? commonLanguages : [settings.targetLanguage] + commonLanguages
    }
}

// MARK: - Translation

struct TranslationTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var keyDraft = ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, running, ok, failed(String) }

    var body: some View {
        let current = settings.apiKey()
        Form {
            Section("API key") {
                HStack {
                    SecureField(current.source == .keychain ? "•••••••• (saved)" : "Paste your API key", text: $keyDraft)
                    Button("Save") { settings.saveKey(keyDraft); keyDraft = ""; testState = .idle }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if current.source == .keychain {
                        Button("Remove", role: .destructive) { settings.saveKey(""); testState = .idle }
                    }
                }
                LabeledContent("Using") {
                    Text(current.source == .none ? "No key found" : current.source.rawValue)
                        .foregroundStyle(current.source == .none ? .red : .secondary)
                }
                Text("Saved keys go in your Mac's Keychain. The extension never sees the key. Get an OpenRouter key at openrouter.ai/keys.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Key file (optional)", text: $settings.keyFile, prompt: Text("~/.config/openrouter.env"))
                    Button("Choose…") { chooseKeyFile() }
                }
                .help("A .env-style file with a line like OPENROUTER_API_KEY=… Used when no key is saved above.")
                HStack {
                    Button("Test connection") { test() }.disabled(testState == .running || current.key == nil)
                    switch testState {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .ok: Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
            Section("Models") {
                TextField("API base URL", text: $settings.baseURL)
                TextField("Speech-to-text model", text: $settings.sttModel)
                TextField("Translation model", text: $settings.rewordModel)
                HStack {
                    Text("Works with OpenRouter or any OpenAI-compatible API (e.g. https://api.openai.com/v1 with whisper-1 and gpt-5-mini).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to defaults") { settings.resetModels() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { settings.keyFile = url.path }
    }

    private func test() {
        guard let key = settings.apiKey().key, let url = URL(string: settings.baseURL) else { return }
        testState = .running
        let t = Translator(baseURL: url, apiKey: key, sttModel: settings.sttModel, rewordModel: settings.rewordModel,
                           targetLanguage: settings.targetLanguage)
        Task { @MainActor in
            do { try await t.check(); testState = .ok } catch { testState = .failed(error.localizedDescription) }
        }
    }
}

// MARK: - Connections

struct ConnectionsTab: View {
    @ObservedObject var bridge = BrowserBridge.shared
    @ObservedObject var overlay = DesktopOverlay.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var dataAccess: Bool?
    @State private var tick = 0
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Status") {
                ForEach(ConnectionStatus.all()) { s in
                    HStack {
                        Circle().fill(color(s.level)).frame(width: 9, height: 9)
                        Text(s.title)
                        Spacer()
                        Text(s.detail).foregroundStyle(.secondary)
                    }
                }
                .id(tick)
            }

            Section("Browser extension (WhatsApp Web)") {
                if bridge.connections.isEmpty {
                    Text("No browser is connected. Install the extension, then open web.whatsapp.com.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bridge.connections) { c in
                        LabeledContent(c.browser) {
                            Text("extension \(c.extensionVersion), connected \(c.since.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Connector registered in") {
                    Text(bridge.registeredBrowsers.isEmpty ? "No browsers found" : bridge.registeredBrowsers.joined(separator: ", "))
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Install Extension…") { ExtensionInstaller.reveal() }
                    Button("Register Again") { bridge.registerNativeHost() }
                        .help("Rewrites the connector files for every installed Chromium browser.")
                }
                if let err = bridge.listenError { Text(err).foregroundStyle(.red) }
            }

            Section("WhatsApp Desktop") {
                LabeledContent("Accessibility") {
                    if overlay.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { overlay.requestAccessibility() }
                    }
                }
                LabeledContent("WhatsApp data") {
                    HStack {
                        switch dataAccess {
                        case .some(true): Label("Readable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .some(false): Label("Blocked by macOS", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        case .none: ProgressView().controlSize(.small)
                        }
                        Button("Check Again") { checkData() }
                    }
                }
                if dataAccess == false {
                    HStack(alignment: .top) {
                        Text("Click Check Again and choose Allow if macOS asks about accessing another app's data. If it doesn't ask, add VoiceNote Translator under Privacy & Security → Full Disk Access (it only ever reads WhatsApp's voice notes).")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }
                Text("Reads the open chat through Accessibility and the voice note files through WhatsApp's local database, both read-only. WhatsApp itself is never modified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in overlay.refreshPermission(); tick += 1 }
        .onAppear { checkData() }
    }

    private func checkData() {
        dataAccess = nil
        Task.detached {
            let ok = WhatsAppDB.canRead()
            await MainActor.run { dataAccess = ok }
        }
    }

    private func color(_ l: ConnectionStatus.Level) -> Color {
        switch l { case .ok: .green; case .warning: .orange; case .off: .secondary }
    }
}

enum ExtensionInstaller {
    /// The extension ships inside the app bundle (Contents/Resources/Extension).
    static var bundled: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Extension")
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
    }

    /// Copies the extension somewhere stable (browsers keep pointing at the folder
    /// you load), shows it in Finder and explains the three clicks needed.
    static func reveal() {
        guard let src = bundled else { return }
        let dest = VNT.supportDirectory.appendingPathComponent("Browser Extension", isDirectory: true)
        try? FileManager.default.createDirectory(at: VNT.supportDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
        NSWorkspace.shared.activateFileViewerSelecting([dest])

        let alert = NSAlert()
        alert.messageText = "Install the browser extension"
        alert.informativeText = """
            1. In Chrome, open chrome://extensions and turn on Developer mode (top right).
            2. Click "Load unpacked" and choose the "Browser Extension" folder now shown in Finder.
            3. Open web.whatsapp.com. The menu bar icon shows "Browser extension: Connected".

            The same works in Brave, Edge, Arc and other Chromium browsers.
            """
        alert.addButton(withTitle: "Copy chrome://extensions")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("chrome://extensions", forType: .string)
        }
    }
}

// MARK: - History

struct HistoryTab: View {
    @ObservedObject var service = TranslationService.shared
    @State private var query = ""
    @State private var selection: UUID?
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("\(service.history.count) translations").foregroundStyle(.secondary)
                Button("Clear All…") { confirmClear = true }.disabled(service.history.isEmpty)
            }
            if filtered.isEmpty {
                ContentUnavailableView(service.history.isEmpty ? "No translations yet" : "No matches",
                                       systemImage: "waveform",
                                       description: Text(service.history.isEmpty ? "Translated voice messages show up here." : ""))
            } else {
                List(filtered, selection: $selection) { e in
                    HistoryRow(entry: e)
                        .contextMenu {
                            Button("Copy Translation") { copy(e.translation.text) }
                            Button("Copy Original") { copy(e.translation.transcript) }
                            Divider()
                            Button("Delete", role: .destructive) { service.delete([e.id]) }
                        }
                }
            }
        }
        .confirmationDialog("Delete all saved translations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { service.clearHistory() }
        }
    }

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return service.history }
        return service.history.filter {
            $0.translation.text.localizedCaseInsensitiveContains(query)
                || $0.translation.transcript.localizedCaseInsensitiveContains(query)
                || ($0.chat ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var showOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.source == .web ? "globe" : "desktopcomputer").foregroundStyle(.secondary)
                Text(entry.chat ?? entry.source.rawValue).fontWeight(.medium)
                if !entry.translation.language.isEmpty {
                    Text("\(entry.translation.language) → \(entry.targetLanguage)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text(showOriginal ? entry.translation.transcript : entry.translation.text)
                .textSelection(.enabled)
                .lineLimit(showOriginal ? nil : 4)
            Button(showOriginal ? "Show translation" : "Show original") { showOriginal.toggle() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(VNT.appName).font(.title2).bold()
            Text("Version \(VNT.version)").foregroundStyle(.secondary)
            Text("Transcribes and translates voice messages in WhatsApp Web and WhatsApp Desktop.")
                .multilineTextAlignment(.center)
            Link("Source code on GitHub", destination: URL(string: "https://github.com/noorfrhx/voicenote-translator")!)
            Spacer().frame(height: 8)
            Text("Open source under the MIT License. Not affiliated with, endorsed or sponsored by WhatsApp or Meta. \"WhatsApp\" is a trademark of WhatsApp LLC.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
