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
    let frame: CGRect      // screen coordinates, top-left origin
    let fromMe: Bool
    let duration: Int      // seconds
    let hour: Int, minute: Int
    let month: Int?, day: Int?
    var key: String { "\(fromMe)|\(duration)|\(month ?? 0)-\(day ?? 0) \(hour):\(minute)" }
}

struct ChatSnapshot {
    let chatName: String
    let visibleArea: CGRect
    let bubbles: [Bubble]
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
    static func y(_ e: AXUIElement) -> CGFloat {
        var p = CGPoint(x: 0, y: -1)
        if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        return p.y
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

/// Picks the database row for a bubble: same sender side, same minute, length within a second.
func match(_ b: Bubble, in notes: [VoiceNote]) -> VoiceNote? {
    let cal = Calendar.current
    return notes.first { n in
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: n.date)
        return n.fromMe == b.fromMe && c.hour == b.hour && c.minute == b.minute
            && abs(Int(n.duration.rounded()) - b.duration) <= 1
            && (b.month == nil || (c.month == b.month && c.day == b.day))
    }
}

/// Reads the open chat from WhatsApp as cheaply as possible.
///
/// Every accessibility query is answered by WhatsApp itself, so reading every
/// message label several times a second made WhatsApp use ~15% more CPU.
/// Instead, `changed()` checks just the list's row count and first/last row
/// positions (3 queries), and the full read only runs when that check or a
/// WhatsApp accessibility event says something moved.
final class WhatsAppReader {
    private var pid: pid_t = 0
    private var observer: AXObserver?
    private var header: AXUIElement?
    private var table: AXUIElement?
    private var signature = ""
    private var lastSearch = Date.distantPast
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

    /// The cheap check: has the list scrolled, moved, or gained rows?
    func changed() -> Bool {
        if dirty { return true }
        guard let table else { return true }
        let rows = AX.children(table)
        guard let first = rows.first, let last = rows.last else { return true }
        let sig = "\(rows.count)|\(AX.y(first))|\(AX.y(last))"
        if sig != signature { signature = sig; return true }
        return false
    }

    /// The full read: one label per visible row, positions only for voice notes.
    @discardableResult
    func read() -> ChatSnapshot? {
        dirty = false
        guard findElements(), let header, let table else { snapshot = nil; return nil }
        let area = AX.frame(table)
        guard !area.isEmpty else { invalidate(refind: true); snapshot = nil; return nil }
        var bubbles: [Bubble] = []
        for row in AX.children(table) {
            let label = AX.string(row, kAXDescriptionAttribute)
            guard label.contains("Duration") else { continue }
            let f = AX.frame(row)
            if f.maxY > area.minY + 4, f.minY < area.maxY - 60, let b = parseBubble(label: label, frame: f) { bubbles.append(b) }
        }
        snapshot = ChatSnapshot(chatName: cleanLabel(AX.string(header, kAXDescriptionAttribute)), visibleArea: area, bubbles: bubbles)
        return snapshot
    }
}
