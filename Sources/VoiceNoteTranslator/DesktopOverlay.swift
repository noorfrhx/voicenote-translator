import AppKit
import ApplicationServices
import Combine

/// Floats a "Translate" button beside every voice bubble in WhatsApp for Mac.
///
/// Nothing runs while WhatsApp is in the background. While it's in front, a
/// cheap check runs every 0.15s and the full read only when something moved.
@MainActor
final class DesktopOverlay: ObservableObject {
    static let shared = DesktopOverlay()

    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var whatsAppRunning = WhatsAppDesktop.runningApp != nil
    @Published private(set) var visibleVoiceNotes = 0

    private let reader = WhatsAppReader()
    private var timer: Timer?
    private var buttons: [BubbleButton] = []
    private var states: [String: NoteState] = [:] { didSet { needsRender = true } }
    private var needsRender = false
    private let result = ResultPanel()
    private var resultKey: String?
    private var notesCache: (chat: String, at: Date, notes: [VoiceNote])?
    private var bag: Set<AnyCancellable> = []

    private init() {}

    func start() {
        result.onClose = { [weak self] in self?.resultKey = nil }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontAppChanged(app) }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.whatsAppRunning = WhatsAppDesktop.runningApp != nil }
            }
        }
        AppSettings.shared.$desktopButtons.dropFirst().sink { [weak self] on in
            if on { self?.frontAppChanged(NSWorkspace.shared.frontmostApplication) } else { self?.stopRefreshing(hide: true) }
        }.store(in: &bag)
        AppSettings.shared.$targetLanguage.dropFirst().sink { [weak self] _ in self?.states.removeAll() }.store(in: &bag)
        frontAppChanged(NSWorkspace.shared.frontmostApplication)
    }

    /// macOS has no notification for this; Settings and the menu call it when they open.
    func refreshPermission() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(opts)
        if !accessibilityTrusted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func frontAppChanged(_ app: NSRunningApplication?) {
        refreshPermission()
        if let app, app.bundleIdentifier == WhatsAppDesktop.bundleID, AppSettings.shared.desktopButtons, accessibilityTrusted {
            reader.attach(app)
            reader.invalidate()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                timer?.tolerance = 0.05
            }
            tick()
        } else if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            // Keep the result panel up while the person is reading or copying from it.
            stopRefreshing(hide: NSApp.keyWindow !== result.panel)
        }
    }

    private func stopRefreshing(hide: Bool) {
        timer?.invalidate()
        timer = nil
        if hide { hideAll() }
    }

    private func hideAll() {
        buttons.forEach { $0.panel.orderOut(nil) }
        result.panel.orderOut(nil)
        resultKey = nil
    }

    private func tick() {
        if reader.changed() {
            reader.read()
            needsRender = true
        }
        if needsRender {
            needsRender = false
            if let snap = reader.snapshot { render(snap) } else { buttons.forEach { $0.panel.orderOut(nil) } }
            visibleVoiceNotes = reader.snapshot?.bubbles.count ?? 0
        }
    }

    private func render(_ snap: ChatSnapshot) {
        while buttons.count < snap.bubbles.count { buttons.append(BubbleButton()) }
        let mid = snap.visibleArea.midX
        var resultBubble: Bubble?
        for (i, bubble) in snap.bubbles.enumerated() {
            let key = snap.chatName + "|" + bubble.key
            // Incoming bubbles sit on the left, so the button goes to their right, and vice versa.
            let leftSide = bubble.frame.midX > mid
            buttons[i].onClick = { [weak self] in self?.clicked(key: key, bubble: bubble, chat: snap.chatName, leftSide: leftSide) }
            buttons[i].show(next: bubble.frame, leftSide: leftSide, state: states[key] ?? .idle)
            if key == resultKey { resultBubble = bubble }
        }
        for b in buttons.dropFirst(snap.bubbles.count) { b.panel.orderOut(nil) }
        if resultKey != nil {
            if let rb = resultBubble { result.place(next: rb.frame, leftSide: rb.frame.midX > mid); result.panel.orderFront(nil) }
            else if NSApp.keyWindow !== result.panel { result.panel.orderOut(nil) }
        }
    }

    private func notes(for chat: String) -> [VoiceNote] {
        if let c = notesCache, c.chat == chat, Date().timeIntervalSince(c.at) < 3 { return c.notes }
        let n = WhatsAppDB.voiceNotes(chatName: chat)
        notesCache = (chat, Date(), n)
        return n
    }

    private func clicked(key: String, bubble: Bubble, chat: String, leftSide: Bool) {
        if case .done(let t) = states[key] {
            if resultKey == key { result.close(); return }
            resultKey = key
            result.show(t, next: bubble.frame, leftSide: leftSide)
            return
        }
        notesCache = nil
        guard let note = match(bubble, in: notes(for: chat)) else {
            states[key] = .failed
            showError(WhatsAppDB.canRead()
                ? "Couldn't find this voice note's audio in WhatsApp's data. If it just arrived, wait a moment and retry."
                : "VoiceNote Translator can't read WhatsApp's data yet. Allow it when macOS asks, or check Settings → Connections.")
            return
        }
        guard let audio = try? Data(contentsOf: note.path) else {
            states[key] = .failed
            showError("WhatsApp hasn't downloaded this voice note yet. Play it once, then try again.")
            return
        }
        states[key] = .busy
        Task { @MainActor in
            do {
                let (t, _) = try await TranslationService.shared.translate(
                    audio: audio, mime: "audio/ogg", cacheKey: "desktop:" + note.path.lastPathComponent, source: .desktop, chat: chat)
                states[key] = .done(t)
                clicked(key: key, bubble: bubble, chat: chat, leftSide: leftSide)
            } catch {
                states[key] = .failed
                showError(error.localizedDescription)
            }
        }
    }

    /// Shows a problem next to the mouse, where the person just clicked.
    private func showError(_ message: String) {
        resultKey = nil
        result.show(Translation(transcript: "", text: "⚠️ " + message, language: ""), at: NSEvent.mouseLocation)
    }
}

// MARK: - Floating UI

enum NoteState { case idle, busy, done(Translation), failed }

final class OverlayPanel: NSPanel {
    init(size: NSSize, key: Bool = false) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = !key
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
    override var canBecomeKey: Bool { true }
}

let brandGreen = NSColor(srgbRed: 0.12, green: 0.66, blue: 0.33, alpha: 1)

/// Screen frame with a top-left origin → Cocoa coordinates.
func cocoaRect(_ r: CGRect) -> NSRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

final class BubbleButton {
    let panel = OverlayPanel(size: NSSize(width: 92, height: 26))
    let button = NSButton()
    var onClick: (() -> Void)?

    init() {
        let v = NSVisualEffectView(frame: panel.contentLayoutRect)
        v.material = .popover
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 13
        v.layer?.borderWidth = 1
        v.layer?.borderColor = brandGreen.withAlphaComponent(0.7).cgColor
        v.autoresizingMask = [.width, .height]
        button.frame = v.bounds
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = brandGreen
        button.target = self
        button.action = #selector(clicked)
        button.setAccessibilityLabel("Translate this voice message")
        v.addSubview(button)
        panel.contentView = v
    }

    @objc func clicked() { onClick?() }

    private var shownState = ""
    static let doneIcon = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Show translation")

    /// Only touches the window when its label or position actually changes.
    func show(next bubble: CGRect, leftSide: Bool, state: NoteState) {
        let key: String
        switch state {
        case .idle: key = "Translate"
        case .busy: key = "Translating…"
        case .done: key = "done"
        case .failed: key = "Retry"
        }
        if shownState != key {
            shownState = key
            // A finished note gets a small round icon instead of a label.
            if key == "done" {
                button.title = ""
                button.image = Self.doneIcon
                button.imagePosition = .imageOnly
                button.toolTip = "Show translation"
                panel.setContentSize(NSSize(width: 30, height: 26))
            } else {
                button.image = nil
                button.imagePosition = .noImage
                button.title = key
                button.toolTip = nil
                panel.setContentSize(NSSize(width: key == "Translating…" ? 104 : 92, height: 26))
            }
            button.isEnabled = key != "Translating…"
        }
        let b = cocoaRect(bubble)
        let x = leftSide ? b.minX - panel.frame.width - 8 : b.maxX + 8
        let origin = NSPoint(x: x, y: b.midY - panel.frame.height / 2)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFront(nil) }
    }
}

final class ResultPanel: NSObject {
    let panel = OverlayPanel(size: NSSize(width: 380, height: 160), key: true)
    let text = NSTextView()
    let meta = NSTextField(labelWithString: "")
    private let scroll = NSScrollView(frame: NSRect(x: 12, y: 38, width: 356, height: 110))
    var translation: Translation?
    var showingOriginal = false
    var onClose: (() -> Void)?

    override init() {
        super.init()
        let v = NSVisualEffectView(frame: panel.contentLayoutRect)
        v.material = .popover
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.autoresizingMask = [.width, .height]

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        // The text view needs a real width from the start; at zero width every
        // line wraps to nothing and the panel looks empty.
        text.frame = NSRect(origin: .zero, size: scroll.contentSize)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 13.5)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        v.addSubview(scroll)

        let copy = link("Copy", #selector(copyText), x: 12)
        let orig = link("Original", #selector(toggleOriginal), x: 62)
        let close = link("Close", #selector(close), x: 322)
        meta.frame = NSRect(x: 130, y: 10, width: 180, height: 16)
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.alignment = .right
        [copy, orig, close, meta].forEach(v.addSubview)
        panel.contentView = v
    }

    private func link(_ title: String, _ action: Selector, x: CGFloat) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.contentTintColor = brandGreen
        b.frame = NSRect(x: x, y: 8, width: title == "Original" ? 62 : 46, height: 20)
        b.alignment = .left
        return b
    }

    func show(_ t: Translation, next bubble: CGRect, leftSide: Bool) {
        translation = t
        showingOriginal = false
        render()
        place(next: bubble, leftSide: leftSide)
        panel.orderFront(nil)
    }

    func show(_ t: Translation, at point: NSPoint) {
        translation = t
        showingOriginal = false
        render()
        panel.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y - panel.frame.height - 12))
        panel.orderFront(nil)
    }

    func place(next bubble: CGRect, leftSide: Bool) {
        let b = cocoaRect(bubble)
        let size = panel.frame.size
        var x = leftSide ? b.minX - size.width - 108 : b.maxX + 108
        let screen = NSScreen.screens.first { $0.frame.intersects(b) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = min(max(b.maxY - size.height, screen.minY + 8), screen.maxY - size.height - 8)
        let origin = NSPoint(x: x, y: y)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private func render() {
        guard let t = translation else { return }
        // Set font and colour with the text: assigning `string` alone can drop them.
        text.textStorage?.setAttributedString(NSAttributedString(
            string: showingOriginal ? t.transcript : t.text,
            attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: NSColor.labelColor]))
        meta.stringValue = showingOriginal ? "Original transcript" : t.language
        // Grow to fit the text, within limits.
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 80
        let h = min(max(used + 52, 90), 420)
        // Only show a scrollbar when the text is longer than the popup can show.
        scroll.hasVerticalScroller = used + 52 > 420
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
    }

    @objc func copyText() {
        guard let t = translation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(showingOriginal ? t.transcript : t.text, forType: .string)
    }
    @objc func toggleOriginal() { showingOriginal.toggle(); render() }
    @objc func close() { panel.orderOut(nil); onClose?() }
}
