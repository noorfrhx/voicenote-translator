import Combine
import Foundation
import VNTCore

/// The app side of the browser connection: a Unix socket that `vnt-host`
/// (started by the browser) relays the extension's messages to.
@MainActor
final class BrowserBridge: ObservableObject {
    static let shared = BrowserBridge()

    struct Connection: Identifiable, Equatable {
        let id: Int
        var browser: String
        var extensionVersion: String
        let since: Date
    }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var listening = false
    @Published private(set) var listenError: String?
    @Published private(set) var registeredBrowsers: [String] = []

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int: Client] = [:]
    private var nextID = 1
    private var bag: Set<AnyCancellable> = []

    private init() {}

    func start() {
        ExtensionInstaller.refreshInstalledCopy()
        registerNativeHost()
        listen()
        // Tell connected extensions when something they show changes.
        let s = AppSettings.shared
        Publishers.Merge3(s.$targetLanguage.map { _ in () }, s.$keyRevision.map { _ in () }, s.$baseURL.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.broadcastStatus() }
            .store(in: &bag)
    }

    // MARK: Native host registration

    /// Opened from the disk image, or from Downloads before being moved, macOS
    /// runs the app from a temporary copy. The connector then points at a path
    /// that soon disappears, and the browser reports the app as not installed.
    static var locationProblem: String? {
        let path = Bundle.main.bundleURL.path
        guard path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") else { return nil }
        return "VoiceNote Translator is running from the disk image or a temporary copy, so browsers can't find it. Quit it, drag it into Applications, and open it from there."
    }

    /// Chromium browsers look for host manifests in their own folder. Write one into
    /// every browser that's installed, pointing at `vnt-host` inside this app bundle.
    func registerNativeHost() {
        let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/vnt-host")
        guard FileManager.default.isExecutableFile(atPath: host.path) else {
            registeredBrowsers = []
            return
        }
        let manifest: [String: Any] = [
            "name": VNT.nativeHostName,
            "description": "\(VNT.appName) bridge",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": VNT.allowedExtensionIDs.map { "chrome-extension://\($0)/" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var done: [String] = []
        for (name, dir) in Self.browsers {
            let browserDir = support.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: browserDir.path) else { continue }
            let hosts = browserDir.appendingPathComponent("NativeMessagingHosts")
            try? FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            if (try? data.write(to: hosts.appendingPathComponent("\(VNT.nativeHostName).json"))) != nil { done.append(name) }
        }
        registeredBrowsers = done
    }

    func unregisterNativeHost() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for (_, dir) in Self.browsers {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(dir)
                .appendingPathComponent("NativeMessagingHosts/\(VNT.nativeHostName).json"))
        }
        registeredBrowsers = []
    }

    static let browsers: [(String, String)] = [
        ("Google Chrome", "Google/Chrome"),
        ("Chrome Beta", "Google/Chrome Beta"),
        ("Chrome Dev", "Google/Chrome Dev"),
        ("Chrome Canary", "Google/Chrome Canary"),
        ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Arc", "Arc/User Data"),
        ("Vivaldi", "Vivaldi"),
    ]

    // MARK: Socket server

    private func listen() {
        let path = VNT.socketPath
        try? FileManager.default.createDirectory(at: VNT.supportDirectory, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { listenError = "Couldn't create the bridge socket."; return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { listenError = "Bridge socket path is too long."; close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            listenError = "Couldn't open the bridge socket (\(String(cString: strerror(errno))))."
            close(fd)
            return
        }
        chmod(path, 0o600)   // only this user's processes may connect
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        acceptSource = source
        listening = true
        listenError = nil
    }

    func stop() {
        acceptSource?.cancel()
        clients.values.forEach { $0.close() }
        if listenFD >= 0 { close(listenFD); unlink(VNT.socketPath) }
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let id = nextID
        nextID += 1
        let client = Client(id: id, fd: fd)
        client.onMessage = { [weak self] msg in self?.handle(msg, from: id) }
        client.onClose = { [weak self] in
            self?.clients[id] = nil
            self?.connections.removeAll { $0.id == id }
        }
        clients[id] = client
        client.start()
    }

    // MARK: Messages

    private func handle(_ msg: [String: Any], from clientID: Int) {
        guard let client = clients[clientID] else { return }
        let id = msg["id"] as? String
        func reply(_ body: [String: Any]) {
            var b = body
            if let id { b["id"] = id }
            client.send(b)
        }

        switch msg["type"] as? String {
        case "hello":
            let c = Connection(id: clientID, browser: msg["browser"] as? String ?? "Browser",
                               extensionVersion: msg["version"] as? String ?? "?", since: Date())
            connections.removeAll { $0.id == clientID }
            connections.append(c)
            reply(statusMessage())

        case "status":
            reply(statusMessage())

        case "lookup":
            let keys = msg["cacheKeys"] as? [String] ?? []
            var results: [String: Any] = [:]
            for k in keys { if let t = TranslationService.shared.cached(cacheKey: k) { results[k] = payload(t, cached: true) } }
            reply(["type": "lookupResult", "results": results])

        case "translate":
            guard let b64 = msg["audio"] as? String, let audio = Data(base64Encoded: b64), !audio.isEmpty else {
                reply(["type": "error", "message": "The extension sent no audio."])
                return
            }
            let mime = msg["mime"] as? String ?? "audio/ogg"
            let cacheKey = msg["cacheKey"] as? String
            let chat = msg["chat"] as? String
            Task { @MainActor in
                do {
                    let (t, cached) = try await TranslationService.shared.translate(
                        audio: audio, mime: mime, cacheKey: cacheKey, source: .web, chat: chat,
                        progress: { stage in reply(["type": "progress", "stage": stage.rawValue]) })
                    reply(["type": "result"].merging(payload(t, cached: cached)) { $1 })
                } catch {
                    reply(["type": "error", "message": error.localizedDescription])
                }
            }

        case "openSettings":
            AppDelegate.shared?.showSettings(tab: SettingsTab(rawValue: msg["tab"] as? String ?? "") ?? .general)
            reply(["type": "ok"])

        default:
            reply(["type": "error", "message": "Unknown request."])
        }
    }

    private func payload(_ t: Translation, cached: Bool) -> [String: Any] {
        ["transcript": t.transcript, "text": t.text, "language": t.language, "cached": cached]
    }

    func statusMessage() -> [String: Any] {
        let problem = AppDelegate.shared?.translationProblem
        var m: [String: Any] = ["type": "status", "appVersion": VNT.version, "ready": problem == nil,
                                "targetLanguage": AppSettings.shared.targetLanguage,
                                "extensionVersion": ExtensionInstaller.bundledVersion ?? ""]
        if let problem { m["problem"] = problem }
        return m
    }

    private func broadcastStatus() {
        let s = statusMessage()
        clients.values.forEach { $0.send(s) }
    }
}

/// One connected `vnt-host`, i.e. one browser profile with the extension running.
private final class Client {
    let id: Int
    let fd: Int32
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?
    private var decoder = FrameDecoder()
    private var source: DispatchSourceRead?
    private let writeQueue: DispatchQueue
    private var closed = false

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
        writeQueue = DispatchQueue(label: "vnt.client.\(id)")
    }

    func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in self?.readAvailable() }
        s.setCancelHandler { [fd] in Darwin.close(fd) }
        s.resume()
        source = s
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { close(); return }
        do {
            for m in try decoder.append(Data(buf[0..<n])) { onMessage?(m) }
        } catch {
            close()
        }
    }

    func send(_ message: [String: Any]) {
        guard !closed, let data = Framing.encode(message) else { return }
        writeQueue.async { [fd] in
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let w = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if w <= 0 { return }
                    offset += w
                }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        onClose?()
    }
}
