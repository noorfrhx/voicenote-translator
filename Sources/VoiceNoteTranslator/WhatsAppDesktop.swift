import AppKit
import ApplicationServices
import SQLite3

// Reading WhatsApp for Mac, without changing it:
// - the open chat and its voice bubbles through macOS Accessibility,
// - each voice note's audio file through WhatsApp's local database.

enum WhatsAppDesktop {
    static let bundleID = "net.whatsapp.WhatsApp"
    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")

    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    static var runningApp: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }
}

// MARK: - Database (read-only)

struct VoiceNote {
    let path: URL
    let date: Date
    let duration: Double
    let fromMe: Bool
}

enum WhatsAppDB {
    static var file: String { WhatsAppDesktop.container.appendingPathComponent("ChatStorage.sqlite").path }

    /// Whether this app can open WhatsApp's database (macOS may ask once for access to other apps' data).
    static func canRead() -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        return sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
            && sqlite3_exec(db, "SELECT 1 FROM ZWAMESSAGE LIMIT 1", nil, nil, nil) == SQLITE_OK
    }

    /// Voice notes in every chat whose name matches the open chat's header.
    static func voiceNotes(chatName: String) -> [VoiceNote] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT i.ZMEDIALOCALPATH, m.ZMESSAGEDATE, i.ZMOVIEDURATION, m.ZISFROMME
            FROM ZWAMESSAGE m
            JOIN ZWAMEDIAITEM i ON i.Z_PK = m.ZMEDIAITEM
            JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            WHERE m.ZMESSAGETYPE = 3 AND s.ZPARTNERNAME = ?
            ORDER BY m.ZMESSAGEDATE DESC LIMIT 400
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, chatName, -1, transient)
        var notes: [VoiceNote] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_text(stmt, 0) else { continue }
            notes.append(VoiceNote(
                path: WhatsAppDesktop.container.appendingPathComponent("Message").appendingPathComponent(String(cString: p)),
                date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)),
                duration: sqlite3_column_double(stmt, 2),
                fromMe: sqlite3_column_int(stmt, 3) == 1))
        }
        return notes
    }
}

// MARK: - Accessibility

struct Bubble {
    let label: String      // the bubble's accessibility description
    var frame: CGRect      // screen coordinates, top-left origin
    let fromMe: Bool
    let duration: Int      // seconds
    let hour: Int, minute: Int
    let month: Int?, day: Int?
    var key: String { "\(fromMe)|\(duration)|\(month ?? 0)-\(day ?? 0) \(hour):\(minute)" }
}

struct ChatSnapshot {
    let chatName: String
    var visibleArea: CGRect
    var bubbles: [Bubble]
    /// Every voice bubble from the last full read, including ones scrolled out
    /// of view, so they can come back while scrolling without a re-read.
    var allBubbles: [Bubble]
}

enum AX {
    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    static func string(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
    static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
    static func position(_ e: AXUIElement) -> CGPoint? {
        var p = CGPoint.zero
        guard let v = attr(e, kAXPositionAttribute) else { return nil }
        AXValueGetValue(v as! AXValue, .cgPoint, &p)
        return p
    }
    static func find(_ e: AXUIElement, id: String, depth: Int = 0) -> AXUIElement? {
        if string(e, "AXIdentifier") == id { return e }
        if depth > 16 { return nil }
        for c in children(e) { if let f = find(c, id: id, depth: depth + 1) { return f } }
        return nil
    }
}

/// Strips the invisible direction marks WhatsApp puts in its labels.
func cleanLabel(_ s: String) -> String {
    s.unicodeScalars.filter { !(0x200E...0x200F).contains($0.value) && !(0x202A...0x202E).contains($0.value) && $0.value != 0xFFFC }
        .map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
}

private let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

/// Parses a bubble label such as "Your voice message, Duration: 16 seconds, 18:20, Played"
/// or "Voice message from Louiss, Duration: 1 minute, 17 seconds, October21,at18:27".
func parseBubble(label raw: String, frame: CGRect) -> Bubble? {
    let label = cleanLabel(raw)
    // Quoted replies ("Replying to …") also mention voice messages; skip them.
    guard let voice = label.range(of: "Duration:", options: .caseInsensitive),
          label[..<voice.lowerBound].range(of: "voice message", options: .caseInsensitive) != nil,
          !label.hasPrefix("Replying to") else { return nil }
    let rest = String(label[voice.upperBound...]).lowercased()
    func number(before unit: String) -> Int {
        guard let r = rest.range(of: "(\\d+)\\s*\(unit)", options: .regularExpression) else { return 0 }
        return Int(rest[r].prefix { $0.isNumber }) ?? 0
    }
    // Older notes read "October21,at18:27", so no word boundary before the time.
    guard let t = rest.range(of: "(?<!\\d)\\d{1,2}:\\d{2}(?!\\d)", options: .regularExpression) else { return nil }
    let hm = rest[t].split(separator: ":").compactMap { Int($0) }
    var month: Int?, day: Int?
    let beforeTime = String(rest[..<t.lowerBound])
    for (i, name) in monthNames.enumerated() {
        if let r = beforeTime.range(of: "\(name)\\s*(\\d{1,2})", options: .regularExpression) {
            month = i + 1
            day = Int(beforeTime[r].filter { $0.isNumber })
        }
    }
    if beforeTime.contains("yesterday") {
        let y = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        month = Calendar.current.component(.month, from: y)
        day = Calendar.current.component(.day, from: y)
    }
    return Bubble(label: label, frame: frame, fromMe: label.lowercased().hasPrefix("your voice message"),
                  duration: number(before: "hour") * 3600 + number(before: "minute") * 60 + number(before: "second"),
                  hour: hm[0], minute: hm[1], month: month, day: day)
}

/// Digits in any script ("١٨:٢٧") as ASCII ones, so labels in every language read the same.
func asciiDigits(_ s: String) -> String {
    String(s.map { c in
        guard c.isNumber, let v = c.wholeNumberValue, (0...9).contains(v) else { return c }
        return Character(String(v))
    })
}

/// Whether a label's hour is this note's hour, on a 24- or 12-hour clock ("18:27" or "6:27 PM").
func sameHour(_ labelHour: Int, _ hour: Int) -> Bool {
    labelHour == hour || (labelHour <= 12 && labelHour % 12 == hour % 12)
}

private let timePattern = try! NSRegularExpression(pattern: "(?<!\\d)(\\d{1,2})[:.](\\d{2})(?!\\d)")
private let numberPattern = try! NSRegularExpression(pattern: "\\d+")

/// Reads a bubble whose label isn't in English. WhatsApp words it in the
/// person's language ("Sprachnachricht von Louis, Dauer: 16 Sekunden, 18:20"),
/// but the length and the time are still numbers. So this looks for a voice
/// note in the open chat whose minute and length both appear in the label.
func parseLocalizedBubble(label raw: String, frame: CGRect, notes: [VoiceNote]) -> Bubble? {
    guard !notes.isEmpty else { return nil }
    let label = asciiDigits(cleanLabel(raw)) as NSString
    let cal = Calendar.current
    for t in timePattern.matches(in: label as String, range: NSRange(location: 0, length: label.length)) {
        guard let h = Int(label.substring(with: t.range(at: 1))), let m = Int(label.substring(with: t.range(at: 2))), m < 60 else { continue }
        let before = label.substring(to: t.range.location)
        let numbers = Set(numberPattern.matches(in: before, range: NSRange(location: 0, length: (before as NSString).length))
            .compactMap { Int((before as NSString).substring(with: $0.range)) })
        guard !numbers.isEmpty else { continue }
        for n in notes {
            let c = cal.dateComponents([.month, .day, .hour, .minute], from: n.date)
            guard c.minute == m, let hour = c.hour, sameHour(h, hour) else { continue }
            // The label rounds the length; allow a second either way.
            let d = Int(n.duration.rounded())
            let named = (d - 1...d + 1).contains { len in
                let parts = [len / 3600, len % 3600 / 60, len % 60].filter { $0 > 0 }
                return !parts.isEmpty && parts.allSatisfy(numbers.contains)
            }
            guard named else { continue }
            return Bubble(label: label as String, frame: frame, fromMe: n.fromMe, duration: d,
                          hour: hour, minute: m, month: c.month, day: c.day)
        }
    }
    return nil
}

/// Picks the database row for a bubble: same sender side, same minute, length within a second.
func match(_ b: Bubble, in notes: [VoiceNote]) -> VoiceNote? {
    let cal = Calendar.current
    return notes.first { n in
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: n.date)
        return n.fromMe == b.fromMe && c.hour.map { sameHour(b.hour, $0) } == true && c.minute == b.minute
            && abs(Int(n.duration.rounded()) - b.duration) <= 1
            && (b.month == nil || (c.month == b.month && c.day == b.day))
    }
}

/// Reads the open chat from WhatsApp as cheaply as possible.
///
/// Every accessibility query is answered by WhatsApp itself, so reading every
/// message label several times a second made WhatsApp use ~15% more CPU.
/// Instead, `check()` looks at just the list's row count and first/last row
/// positions (3 queries), and the full read only runs when that check or a
/// WhatsApp accessibility event says something moved.
final class WhatsAppReader {
    private var pid: pid_t = 0
    private var observer: AXObserver?
    private var header: AXUIElement?
    private var table: AXUIElement?
    private var lastSearch = Date.distantPast
    private var notesCache: (chat: String, at: Date, notes: [VoiceNote])?
    private(set) var dirty = true
    private(set) var snapshot: ChatSnapshot?

    func attach(_ app: NSRunningApplication) {
        guard app.processIdentifier != pid else { return }
        detach()
        pid = app.processIdentifier
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, note, ctx in
            let reader = Unmanaged<WhatsAppReader>.fromOpaque(ctx!).takeUnretainedValue()
            reader.invalidate(refind: (note as String) == kAXFocusedWindowChangedNotification)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let root = AXUIElementCreateApplication(pid)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXLayoutChangedNotification, kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                  kAXUIElementDestroyedNotification, kAXCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(obs, root, n as CFString, ctx)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    func detach() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil
        pid = 0
        invalidate(refind: true)
    }

    /// Something in WhatsApp changed; do a full read on the next refresh.
    /// Searching the window for the header and list again is the costly part,
    /// so that only happens when the window changed or they stop answering.
    func invalidate(refind: Bool = false) {
        dirty = true
        if refind { header = nil; table = nil }
    }

    private func findElements() -> Bool {
        if header != nil, table != nil { return true }
        // With no chat open there's nothing to find; don't search the whole window on every refresh.
        guard Date().timeIntervalSince(lastSearch) > 1 else { return false }
        lastSearch = Date()
        let root = AXUIElementCreateApplication(pid)
        guard let w = AX.attr(root, kAXFocusedWindowAttribute) else { return false }
        let window = w as! AXUIElement
        header = AX.find(window, id: "NavigationBar_HeaderViewButton")
        table = AX.find(window, id: "ChatMessagesTableView")
        return header != nil && table != nil
    }

    /// The open chat's voice notes, for labels in other languages; re-read every few seconds at most.
    private func localizedNotes(_ chat: String) -> [VoiceNote] {
        if let c = notesCache, c.chat == chat, Date().timeIntervalSince(c.at) < 3 { return c.notes }
        let n = WhatsAppDB.voiceNotes(chatName: chat)
        notesCache = (chat, Date(), n)
        return n
    }

    enum Change: Equatable {
        case same
        /// Every row moved by the same amount: a scroll or a window move.
        case moved(dx: CGFloat, dy: CGFloat)
        /// Rows appeared, disappeared or moved relative to each other.
        case changed
    }

    /// One row from the last full read, followed to measure scrolling, and the
    /// number of rows then. While it stays the same row, its movement is the
    /// list's movement.
    private var anchor: (row: AXUIElement, position: CGPoint)?
    private var rowCount = 0
    /// Rows were added or removed since the last full read (e.g. while scrolling).
    private(set) var rowsChanged = false

    /// The cheap check (2 queries): the row count and the anchor row's position.
    func check() -> Change {
        if dirty { return .changed }
        guard let table, let anchor else { return .changed }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(table, kAXChildrenAttribute as CFString, &count) == .success,
              let pos = AX.position(anchor.row) else { return .changed }   // the anchor row is gone
        if count != rowCount { rowsChanged = true }
        let d = CGPoint(x: pos.x - anchor.position.x, y: pos.y - anchor.position.y)
        self.anchor = (anchor.row, pos)
        if d != .zero { return .moved(dx: d.x, dy: d.y) }
        return rowsChanged ? .changed : .same
    }

    /// Moves the last snapshot by a scroll or window-move delta without
    /// re-reading any labels (1 query, for the list's own frame).
    func shift(dx: CGFloat, dy: CGFloat) {
        guard var snap = snapshot, let table else { return }
        let area = AX.frame(table)
        snap.visibleArea = area
        snap.allBubbles = snap.allBubbles.map { var b = $0; b.frame = b.frame.offsetBy(dx: dx, dy: dy); return b }
        snap.bubbles = snap.allBubbles.filter { Self.isVisible($0.frame, in: area) }
        snapshot = snap
    }

    private static func isVisible(_ f: CGRect, in area: CGRect) -> Bool {
        f.maxY > area.minY + 4 && f.minY < area.maxY - 60
    }

    /// The full read: one label per row, positions only for voice notes.
    @discardableResult
    func read() -> ChatSnapshot? {
        dirty = false
        guard findElements(), let header, let table else { snapshot = nil; return nil }
        let area = AX.frame(table)
        guard !area.isEmpty else { invalidate(refind: true); snapshot = nil; return nil }
        let chatName = cleanLabel(AX.string(header, kAXDescriptionAttribute))
        var all: [Bubble] = []
        var english = false
        var other: [(label: String, row: AXUIElement)] = []
        let rows = AX.children(table)
        for row in rows {
            let label = AX.string(row, kAXDescriptionAttribute)
            if label.contains("Duration") {
                english = true
                if let b = parseBubble(label: label, frame: AX.frame(row)) { all.append(b) }
            } else if label.contains(where: \.isNumber) {
                other.append((label, row))
            }
        }
        // WhatsApp isn't in English: recognise voice notes from its database instead.
        if !english, !other.isEmpty {
            let notes = localizedNotes(chatName)
            for o in other {
                if let b = parseLocalizedBubble(label: o.label, frame: AX.frame(o.row), notes: notes) { all.append(b) }
            }
        }
        // Follow a row from the middle of the list: the ones at the edges are
        // the first to be recycled while scrolling.
        let mid = rows.isEmpty ? nil : rows[rows.count / 2]
        anchor = mid.flatMap { r in AX.position(r).map { (r, $0) } }
        rowCount = rows.count
        rowsChanged = false
        snapshot = ChatSnapshot(chatName: chatName, visibleArea: area,
                                bubbles: all.filter { Self.isVisible($0.frame, in: area) }, allBubbles: all)
        return snapshot
    }
}
