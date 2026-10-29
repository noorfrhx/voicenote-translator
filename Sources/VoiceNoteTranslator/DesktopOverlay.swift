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
        result.onClose = { [weak self] in
            self?.resultKey = nil
            // The popup had the keyboard; hand it back to WhatsApp.
            WhatsAppDesktop.runningApp?.activate()
        }
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
        let now = AXIsProcessTrusted()
        if now != accessibilityTrusted {
            accessibilityTrusted = now
            // Just allowed while WhatsApp is open: start without waiting for it to be clicked.
            if now { frontAppChanged(NSWorkspace.shared.frontmostApplication) }
        }
    }

    func requestAccessibility() {
        PermissionGuide.shared.start(.accessibility)
    }

    private func frontAppChanged(_ app: NSRunningApplication?) {
        refreshPermission()
        if let app, app.bundleIdentifier == WhatsAppDesktop.bundleID, AppSettings.shared.desktopButtons, accessibilityTrusted {
            reader.attach(app)
            reader.invalidate()
            setRate(fast: false)
            tick()
        } else if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            stopRefreshing(hide: true)
        }
    }

    // While the chat scrolls or the window moves, follow at 60 fps; otherwise a
    // cheap check every 0.15s is enough.
    private static let slowInterval = 0.15
    private static let fastInterval = 1.0 / 60
    private var fast = false
    private var lastMotion = Date.distantPast
    private var lastRead = Date.distantPast
    private var settled = true

    private func fullRead(_ now: Date) {
        reader.read()
        lastRead = now
    }

    private func setRate(fast: Bool) {
        if timer != nil, self.fast == fast { return }
        self.fast = fast
        timer?.invalidate()
        let interval = fast ? Self.fastInterval : Self.slowInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = fast ? 0.004 : 0.05
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
        let now = Date()
        switch reader.check() {
        case .same:
            // Motion just stopped: one accurate read to pick up rows that scrolled into view.
            if !settled, now.timeIntervalSince(lastMotion) > 0.12 {
                settled = true
                fullRead(now)
                needsRender = true
            }
        case .moved(let dx, let dy):
            // Scroll or window move: shift what's on screen without re-reading
            // labels. If rows also came or went, re-read, but at most 4 times a
            // second while moving; one more read follows when motion stops.
            reader.shift(dx: dx, dy: dy)
            if reader.rowsChanged, now.timeIntervalSince(lastRead) > 0.25 { fullRead(now) }
            needsRender = true
            lastMotion = now
            settled = false
        case .changed:
            fullRead(now)
            needsRender = true
            settled = true
        }
        setRate(fast: now.timeIntervalSince(lastMotion) < 0.5)
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

    /// Sees key presses before the text view does, for the popup's shortcuts.
    var keyHandler: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
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
        copy.toolTip = "Copy (⌘C)"
        orig.toolTip = "Switch between translation and original (Tab)"
        close.toolTip = "Close (Esc)"
        close.autoresizingMask = [.minXMargin]
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
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

    /// Where the popup would like to be: beside the bubble, top edges aligned.
    /// `fit()` then keeps it on screen.
    private var anchor: (bubble: NSRect, leftSide: Bool)?
    private var anchorPoint: NSPoint?

    func show(_ t: Translation, next bubble: CGRect, leftSide: Bool) {
        translation = t
        showingOriginal = false
        anchor = (cocoaRect(bubble), leftSide)
        anchorPoint = nil
        present()
    }

    func show(_ t: Translation, at point: NSPoint) {
        translation = t
        showingOriginal = false
        anchor = nil
        anchorPoint = point
        present()
    }

    private func present() {
        render()
        // Take keyboard focus (Esc, ⌘C, Tab) without activating this app, so
        // WhatsApp stays the front app and gets the keyboard back on close.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(text)
    }

    func place(next bubble: CGRect, leftSide: Bool) {
        anchor = (cocoaRect(bubble), leftSide)
        fit()
    }

    /// The visible area of the screen the popup belongs on.
    private var screenFrame: NSRect {
        let probe = anchor?.bubble.center ?? anchorPoint ?? panel.frame.center
        return (NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }

    /// Positions the popup by its anchor and keeps the whole of it on screen.
    private func fit() {
        let screen = screenFrame
        let size = panel.frame.size
        var origin: NSPoint
        if let (b, leftSide) = anchor {
            origin = NSPoint(x: leftSide ? b.minX - size.width - 44 : b.maxX + 44, y: b.maxY - size.height)
        } else if let p = anchorPoint {
            origin = NSPoint(x: p.x + 12, y: p.y - size.height - 12)
        } else {
            origin = panel.frame.origin
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private func render() {
        guard let t = translation else { return }
        // Set font and colour with the text: assigning `string` alone can drop them.
        text.textStorage?.setAttributedString(NSAttributedString(
            string: showingOriginal ? t.transcript : t.text,
            attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: NSColor.labelColor]))
        text.scrollToBeginningOfDocument(nil)
        meta.stringValue = showingOriginal ? (t.language.isEmpty ? "Original" : "Original · \(t.language)") : t.language
        // Grow to fit the text, but never taller than the screen allows.
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 80
        let maxHeight = min(460, screenFrame.height - 16)
        let h = min(max(used + 52, 90), maxHeight)
        // Only show a scrollbar when the text is longer than the popup can show.
        scroll.hasVerticalScroller = used + 52 > maxHeight
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
        fit()
    }

    @objc func copyText() {
        guard let t = translation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(showingOriginal ? t.transcript : t.text, forType: .string)
    }
    @objc func toggleOriginal() { showingOriginal.toggle(); render() }
    @objc func close() { panel.orderOut(nil); onClose?() }

    /// Keyboard: Esc or ⌘W closes, ⌘C copies (everything, when nothing is selected), Tab switches to the original.
    func handleKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        switch (event.keyCode, cmd, event.charactersIgnoringModifiers?.lowercased()) {
        case (53, _, _), (_, true, "w"):
            close()
            return true
        case (_, true, "c") where text.selectedRange().length == 0:
            copyText()
            return true
        case (48, false, _):
            toggleOriginal()
            return true
        default:
            return false
        }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
