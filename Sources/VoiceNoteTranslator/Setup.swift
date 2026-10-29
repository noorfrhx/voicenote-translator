import AppKit
import ApplicationServices
import Combine
import SwiftUI
import VNTCore

// MARK: - Running from Applications

/// Makes sure the app runs from the Applications folder.
///
/// Opened straight from the disk image or from Downloads, macOS runs a
/// temporary read-only copy ("App Translocation") whose path changes on every
/// launch. Browsers then can't find the connector ("app isn't installed"), and
/// the permission lists in System Settings show a copy people can't find.
/// So the app offers to move itself, and won't run anywhere else.
enum AppMover {
    static var isTranslocated: Bool { Bundle.main.bundleURL.path.contains("/AppTranslocation/") }

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let folders = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"]
        return !isTranslocated && folders.contains { path.hasPrefix($0) }
    }

    static var destination: URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
    }

    /// Where the person actually put the app, before macOS translocated it.
    static var originalURL: URL? {
        let url = Bundle.main.bundleURL
        guard isTranslocated else { return url }
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        return unsafeBitCast(sym, to: Fn.self)(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// Moves the app into Applications and reopens it from there, or quits.
    /// Returns only when the app may keep running where it is.
    @MainActor
    static func moveIfNeeded() {
        #if DEBUG
        return
        #else
        guard Bundle.main.bundleURL.pathExtension == "app", !isInApplications,
              !CommandLine.arguments.contains("--any-location") else { return }
        let original = originalURL
        let onDiskImage = original?.path.hasPrefix("/Volumes/") ?? false

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Move \(VNT.appName) to Applications?"
        alert.informativeText = (onDiskImage
            ? "It's running from the disk image. "
            : "It's running from \(original.map { "“\($0.deletingLastPathComponent().lastPathComponent)”" } ?? "a temporary folder"). ")
            + "It has to live in Applications so your browser can find it and macOS remembers its permissions. It will move itself and open again."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { exit(0) }

        do {
            try install(from: Bundle.main.bundleURL, to: destination)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn't move \(VNT.appName)"
            fail.informativeText = "\(error.localizedDescription)\n\nDrag \(VNT.appName) into the Applications folder in Finder, then open it from there."
            fail.runModal()
            if let original { NSWorkspace.shared.activateFileViewerSelecting([original]) }
            exit(0)
        }

        // Tidy up the copy it was opened from: eject the disk image, or move the
        // downloaded copy to the Trash so there's only one app to find.
        var eject: String?
        if onDiskImage, let original {
            eject = "/" + original.pathComponents.prefix(3).dropFirst().joined(separator: "/")
        } else if let original, original != destination, !original.path.contains("/AppTranslocation/") {
            try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
        }
        relaunch(at: destination, eject: eject)
        #endif
    }

    private static func install(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: src, to: dest)
        } catch {
            // Applications isn't writable for this account: ask for an administrator.
            try runAsAdmin("/bin/rm -rf \(shellQuote(dest.path)) && /bin/cp -R \(shellQuote(src.path)) \(shellQuote(dest.path))")
        }
        // A copy keeps the download's quarantine flag, which would make macOS
        // translocate it again. Finder clears it when you drag the app; so do we.
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? x.run()
        x.waitUntilExit()
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ command: String) throws {
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var info: NSDictionary?
        NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges")?.executeAndReturnError(&info)
        if let info {
            throw NSError(domain: "AppMover", code: 1, userInfo: [NSLocalizedDescriptionKey:
                info[NSAppleScript.errorMessage] as? String ?? "Permission to change the Applications folder was refused."])
        }
    }

    /// Quits, then opens the app at `url` once this process has gone (only one
    /// copy may run at a time).
    static func relaunch(at url: URL = Bundle.main.bundleURL, eject: String? = nil) -> Never {
        let pid = ProcessInfo.processInfo.processIdentifier
        var script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\""
        if eject != nil { script += "; /usr/bin/hdiutil detach -quiet \"$2\" || true" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", url.path] + (eject.map { [$0] } ?? [])
        try? p.run()
        exit(0)
    }
}

// MARK: - Permissions

/// Whether WhatsApp's data can be read, checked in one place so the menu,
/// Settings and the setup guide agree. (Accessibility is `DesktopOverlay.accessibilityTrusted`.)
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    /// Whether WhatsApp's database can be read; nil while checking.
    @Published private(set) var whatsAppData: Bool?

    private init() {}

    /// Reading WhatsApp's data may make macOS ask once about another app's data.
    func checkData() {
        Task.detached {
            let ok = WhatsAppDB.canRead()
            await MainActor.run { if Permissions.shared.whatsAppData != ok { Permissions.shared.whatsAppData = ok } }
        }
    }
}

/// A small window beside System Settings that says exactly what to do, offers
/// the app's icon to drag into the list (no "+" and file browsing), and closes
/// itself as soon as the permission is on.
@MainActor
final class PermissionGuide: ObservableObject {
    static let shared = PermissionGuide()

    enum Kind {
        case accessibility, fullDiskAccess
        var title: String { self == .accessibility ? "Allow Accessibility" : "Allow Full Disk Access" }
        var why: String {
            self == .accessibility
                ? "Lets \(VNT.appName) see the voice messages in the open WhatsApp chat to put a Translate button next to them."
                : "Lets \(VNT.appName) read the voice note files WhatsApp keeps on this Mac. It only reads voice notes and never changes anything."
        }
        var pane: String { self == .accessibility ? "Privacy_Accessibility" : "Privacy_AllFiles" }
    }

    @Published private(set) var kind: Kind = .accessibility
    @Published private(set) var granted = false
    @Published private(set) var waitingSince = Date()

    private var panel: NSPanel?
    private var timer: Timer?

    private init() {}

    func start(_ kind: Kind) {
        // Already allowed? Nothing to do.
        if kind == .accessibility, AXIsProcessTrusted() { DesktopOverlay.shared.refreshPermission(); return }
        if kind == .fullDiskAccess, WhatsAppDB.canRead() { Permissions.shared.checkData(); return }

        self.kind = kind
        granted = false
        waitingSince = Date()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.pane)")!)
        show()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionGuide.shared.poll() }
        }
    }

    /// For `--render-screenshots`: shows the guide's text without opening anything.
    func preview(_ kind: Kind, granted: Bool = false) {
        self.kind = kind
        self.granted = granted
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func poll() {
        let ok: Bool
        switch kind {
        case .accessibility:
            DesktopOverlay.shared.refreshPermission()
            ok = DesktopOverlay.shared.accessibilityTrusted
        case .fullDiskAccess:
            ok = WhatsAppDB.canRead()
            if ok { Permissions.shared.checkData() }
        }
        guard ok, !granted else { return }
        granted = true
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.close()
            AppDelegate.shared?.showSettings(tab: .connections)
        }
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = VNT.appName
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: PermissionGuideView(guide: self))
            panel = p
        }
        guard let panel else { return }
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        place(panel)
        panel.orderFrontRegardless()
        // System Settings takes a moment to open; move next to it once it's there.
        for delay in [0.6, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let p = self.panel, p.isVisible else { return }
                self.place(p)
            }
        }
    }

    /// Beside the System Settings window when it can be found, else at the screen's right edge.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.midY - panel.frame.height / 2)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if let info = windows.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "System Settings" && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let b = info[kCGWindowBounds as String] as? [String: CGFloat],
           let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] {
            let settings = cocoaRect(CGRect(x: x, y: y, width: w, height: h))
            let right = settings.maxX + 12
            origin.x = right + panel.frame.width <= screen.maxX ? right : max(screen.minX, settings.minX - panel.frame.width - 12)
            origin.y = min(max(settings.maxY - panel.frame.height, screen.minY), screen.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)
    }
}

struct PermissionGuideView: View {
    @ObservedObject var guide: PermissionGuide
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(guide.kind.title).font(.headline)
            Text(guide.kind.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if guide.granted {
                Label("Allowed. You're all set.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.body.weight(.medium))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turn on **\(VNT.appName)** in the list.")
                    Text("Not in the list? Drag this icon into it:")
                }
                .font(.callout)
                HStack(spacing: 10) {
                    DraggableAppIcon().frame(width: 56, height: 56)
                    Text(VNT.appName).font(.callout.weight(.medium))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                if guide.kind == .fullDiskAccess {
                    Text("If macOS offers to “Quit & Reopen” the app, click it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the switch…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // Full Disk Access sometimes only applies after a restart.
                    if guide.kind == .fullDiskAccess, now.timeIntervalSince(guide.waitingSince) > 8 {
                        Button("Reopen App") { AppMover.relaunch() }.controlSize(.small)
                    }
                    Button("Close") { guide.close() }.controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(tick) { now = $0 }
    }
}

/// The app's icon, draggable as the app itself, so it can be dropped straight
/// into a list in System Settings.
struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> DragIconView { DragIconView() }
    func updateNSView(_ nsView: DragIconView, context: Context) {}

    final class DragIconView: NSImageView, NSDraggingSource {
        init() {
            super.init(frame: .zero)
            image = NSApp.applicationIconImage
            imageScaling = .scaleProportionallyUpOrDown
            toolTip = "Drag into the list in System Settings"
            unregisterDraggedTypes()   // a source only, not a drop target
        }
        required init?(coder: NSCoder) { fatalError() }

        // Sized by SwiftUI's frame, not by the 1024-pixel icon.
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
