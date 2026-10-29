import AppKit
import Combine
import ServiceManagement
import SwiftUI
import VNTCore

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon until a window opens
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static private(set) weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settingsModel = SettingsWindowModel()
    private var bag: Set<AnyCancellable> = []

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One copy only: the bridge socket can't be shared.
        if CommandLine.arguments.contains("--render-screenshots") { return }
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: VNT.bundleID).first(where: { $0.processIdentifier != me }) {
            other.activate()
            DistributedNotificationCenter.default().postNotificationName(.init("\(VNT.bundleID).showSettings"), object: nil, deliverImmediately: true)
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--render-screenshots <folder>`: draw each Settings tab to a PNG (for docs) and quit.
        if let i = CommandLine.arguments.firstIndex(of: "--render-screenshots"), i + 1 < CommandLine.arguments.count {
            renderScreenshots(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = VNT.appName
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        BrowserBridge.shared.start()
        DesktopOverlay.shared.start()

        // Keep the menu bar icon in step with the connection state.
        Publishers.MergeMany(
            BrowserBridge.shared.$connections.map { _ in () }.eraseToAnyPublisher(),
            DesktopOverlay.shared.$accessibilityTrusted.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$keyRevision.map { _ in () }.eraseToAnyPublisher(),
            TranslationService.shared.$activeCount.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updateIcon() }
        .store(in: &bag)

        // Opening the app a second time shows Settings; the notification may name a tab.
        DistributedNotificationCenter.default().addObserver(forName: .init("\(VNT.bundleID).showSettings"), object: nil, queue: .main) { n in
            let tab = (n.object as? String).flatMap(SettingsTab.init(rawValue:)) ?? .general
            MainActor.assumeIsolated { AppDelegate.shared?.showSettings(tab: tab) }
        }

        // A menu bar utility should come back after a restart: open at login by
        // default, once. The switch in Settings → General turns it off for good.
        if !UserDefaults.standard.bool(forKey: "didSetLoginDefault") {
            UserDefaults.standard.set(true, forKey: "didSetLoginDefault")
            try? LaunchAtLogin.set(true)
        }

        // First run: show Settings so the person can add a key and see what's connected.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            showSettings(tab: AppSettings.shared.apiKey().key == nil ? .translation : .connections)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserBridge.shared.stop()
    }

    // Reopening the app from Finder or Launchpad shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(tab: .general)
        return true
    }

    // MARK: Status

    /// Why translations can't run right now, or nil when they can.
    var translationProblem: String? {
        let s = AppSettings.shared
        if s.apiKey().key == nil { return "No API key. Add one in VoiceNote Translator → Settings → Translation." }
        if URL(string: s.baseURL)?.scheme == nil { return "The API base URL in Settings isn't valid." }
        return nil
    }

    private func updateIcon() {
        let busy = TranslationService.shared.activeCount > 0
        let problem = translationProblem != nil
        let name = problem ? "waveform.badge.exclamationmark" : (busy ? "waveform.circle.fill" : "waveform.badge.mic")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: VNT.appName)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: VNT.appName)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        DesktopOverlay.shared.refreshPermission()
        menu.removeAllItems()

        let title = NSMenuItem(title: VNT.appName, action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: VNT.appName, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(title)
        for s in ConnectionStatus.all() {
            let item = NSMenuItem(title: "\(s.title): \(s.detail)", action: #selector(openConnections), keyEquivalent: "")
            item.target = self
            item.image = statusDot(s.level)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Buttons in WhatsApp Desktop", action: #selector(toggleDesktopButtons), keyEquivalent: "")
        pause.target = self
        pause.state = AppSettings.shared.desktopButtons ? .on : .off
        menu.addItem(pause)

        let langs = NSMenuItem(title: "Translate Into", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = AppSettings.shared.targetLanguage
        var options = ["English", "German", "Arabic", "French", "Spanish", "Turkish", "Urdu"]
        if !options.contains(current) { options.insert(current, at: 0) }
        for lang in options {
            let i = NSMenuItem(title: lang, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            i.target = self
            i.state = lang == current ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(openTranslation), keyEquivalent: "")
        other.target = self
        sub.addItem(other)
        langs.submenu = sub
        menu.addItem(langs)

        menu.addItem(.separator())
        addItem(menu, "Recent Translations…", #selector(openHistory))
        addItem(menu, "Settings…", #selector(openGeneral), key: ",")
        addItem(menu, "About \(VNT.appName)", #selector(openAbout))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(VNT.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    private func statusDot(_ level: ConnectionStatus.Level) -> NSImage {
        let color: NSColor = switch level { case .ok: .systemGreen; case .warning: .systemOrange; case .off: .tertiaryLabelColor }
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func toggleDesktopButtons() { AppSettings.shared.desktopButtons.toggle() }
    @objc private func pickLanguage(_ sender: NSMenuItem) { AppSettings.shared.targetLanguage = sender.title }
    @objc private func openGeneral() { showSettings(tab: .general) }
    @objc private func openTranslation() { showSettings(tab: .translation) }
    @objc private func openConnections() { showSettings(tab: .connections) }
    @objc private func openHistory() { showSettings(tab: .history) }
    @objc private func openAbout() { showSettings(tab: .about) }

    // MARK: Settings window

    func showSettings(tab: SettingsTab) {
        settingsModel.tab = tab
        DesktopOverlay.shared.refreshPermission()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "\(VNT.appName) Settings"
            w.contentView = NSHostingView(rootView: SettingsView(model: settingsModel))
            w.minSize = NSSize(width: 600, height: 440)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("SettingsWindow")
            settingsWindow = w
        }
        // Show in the Dock and app switcher while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func renderScreenshots(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for tab in SettingsTab.allCases {
            let model = SettingsWindowModel()
            model.tab = tab
            let view = NSHostingView(rootView: SettingsView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("settings-\(tab.rawValue).png"))
        }

        // The WhatsApp Desktop overlay: the result popup and each button state.
        let sample = Translation(transcript: "Hallo Bruder, ich kann es nicht nachvollziehen, was er da meint.",
                                 text: "Hey brother, I can't make sense of what he means. The tire pressure was low anyway, and we fixed that. With the right pressure the suspension feels a bit firmer, but that's how it should be.",
                                 language: "German")
        let result = ResultPanel()
        result.show(sample, at: NSPoint(x: 200, y: 600))
        snapshot(result.panel, to: folder.appendingPathComponent("overlay-result.png"))
        result.panel.orderOut(nil)

        // A very long note near the bottom of the screen must stay fully on screen.
        let long = Translation(transcript: String(repeating: "Das ist ein sehr langer Satz in einer Sprachnachricht, damit das Fenster scrollen muss. ", count: 40),
                               text: sample.text, language: "German")
        let screen = NSScreen.main!.visibleFrame
        result.show(long, at: NSPoint(x: screen.midX, y: screen.minY + 40))
        result.toggleOriginal()
        let f = result.panel.frame
        print("long popup \(f), on screen: \(screen.contains(f))")
        snapshot(result.panel, to: folder.appendingPathComponent("overlay-result-long.png"))
        result.panel.orderOut(nil)
        for (name, state) in [("idle", NoteState.idle), ("busy", .busy), ("done", .done(sample)), ("failed", .failed)] {
            let b = BubbleButton()
            b.show(next: CGRect(x: 100, y: 300, width: 300, height: 70), leftSide: false, state: state)
            snapshot(b.panel, to: folder.appendingPathComponent("overlay-button-\(name).png"))
            b.panel.orderOut(nil)
        }
    }

    private func snapshot(_ window: NSWindow, to url: URL) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

final class SettingsWindowModel: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// One line of "is everything connected?", shared by the menu and the Connections tab.
struct ConnectionStatus: Identifiable {
    enum Level { case ok, warning, off }
    let id: String
    let title: String
    let detail: String
    let level: Level

    @MainActor
    static func all() -> [ConnectionStatus] {
        var out: [ConnectionStatus] = []

        let conns = BrowserBridge.shared.connections
        if conns.isEmpty {
            out.append(.init(id: "browser", title: "Browser extension", detail: "Not connected", level: .warning))
        } else {
            let names = Array(Set(conns.map(\.browser))).sorted().joined(separator: ", ")
            out.append(.init(id: "browser", title: "Browser extension", detail: "Connected (\(names))", level: .ok))
        }

        let overlay = DesktopOverlay.shared
        if !AppSettings.shared.desktopButtons {
            out.append(.init(id: "desktop", title: "WhatsApp Desktop", detail: "Buttons turned off", level: .off))
        } else if !WhatsAppDesktop.isInstalled {
            out.append(.init(id: "desktop", title: "WhatsApp Desktop", detail: "Not installed", level: .off))
        } else if !overlay.accessibilityTrusted {
            out.append(.init(id: "desktop", title: "WhatsApp Desktop", detail: "Needs Accessibility permission", level: .warning))
        } else {
            out.append(.init(id: "desktop", title: "WhatsApp Desktop", detail: overlay.whatsAppRunning ? "Ready" : "Ready (WhatsApp not open)", level: .ok))
        }

        if let problem = AppDelegate.shared?.translationProblem {
            out.append(.init(id: "api", title: "Translation", detail: problem.hasPrefix("No API key") ? "No API key" : "Check settings", level: .warning))
        } else {
            out.append(.init(id: "api", title: "Translation", detail: "Ready, into \(AppSettings.shared.targetLanguage)", level: .ok))
        }
        return out
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
