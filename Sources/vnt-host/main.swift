// Native messaging host for the VoiceNote Translator browser extension.
//
// The browser starts this for the extension (chrome.runtime.connectNative) and
// talks to it over stdin/stdout, using 4-byte-length + JSON frames. It relays
// those messages to the running app's Unix socket (same framing).
//
// It outlives the app: when the app quits or restarts, this process tells the
// extension the app is offline, checks for the app every 2 seconds and, when
// it's back, replays the extension's `hello` so the app sees the browser again.
// The browser's connection never drops, so the extension needs no retry logic
// of its own (browsers suspend extension workers and their timers freely).
//
// It only starts the app for things the person did (Translate, Open settings,
// Reconnect), never on its own, so quitting the app keeps it quit.

import Foundation
import VNTCore

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

let stdoutLock = NSLock()
func reply(_ object: [String: Any]) {
    guard let data = Framing.encode(object) else { return }
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let w = write(STDOUT_FILENO, raw.baseAddress! + off, raw.count - off)
            if w <= 0 { exit(0) }   // the browser went away
            off += w
        }
    }
}

// The browser passes the caller's origin as the first argument; it already
// enforces allowed_origins, but refuse anything unexpected anyway.
let origin = CommandLine.arguments.dropFirst().first ?? ""
if !VNT.allowedExtensionIDs.contains(where: { origin.contains($0) }) {
    reply(["type": "error", "message": "This extension isn't allowed to use VoiceNote Translator."])
    exit(1)
}

// MARK: Socket

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = VNT.socketPath
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let n = min(path.utf8.count, raw.count - 1)
        raw.copyBytes(from: path.utf8.prefix(n))
        raw[n] = 0
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if ok == 0 { return fd }
    close(fd)
    return nil
}

func launchApp() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", VNT.bundleID]   // -g: start in the background
    try? p.run()
    p.waitUntilExit()
}

/// Shared state, guarded by `lock`.
let lock = NSLock()
var appFD: Int32 = -1
var hello: [String: Any]?       // the extension's latest hello, replayed on every reconnect
var watching = false            // a background loop is waiting for the app

func sendToApp(_ message: [String: Any]) -> Bool {
    guard let data = Framing.encode(message) else { return true }
    lock.lock()
    let fd = appFD
    lock.unlock()
    guard fd >= 0 else { return false }
    return data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let w = write(fd, raw.baseAddress! + off, raw.count - off)
            if w <= 0 { return false }
            off += w
        }
        return true
    }
}

/// Connects (if the app is up), replays the hello, and starts relaying the app's replies.
@discardableResult
func attach() -> Bool {
    lock.lock()
    if appFD >= 0 { lock.unlock(); return true }
    guard let fd = connectSocket() else { lock.unlock(); return false }
    appFD = fd
    let h = hello
    lock.unlock()
    if let h { _ = sendToApp(h) }
    Thread.detachNewThread { relayFromApp(fd) }
    return true
}

/// App → browser: copied unchanged, since the framing is the same. When the app
/// goes away, tell the extension and wait for it to come back.
func relayFromApp(_ fd: Int32) {
    var buf = [UInt8](repeating: 0, count: 256 * 1024)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        stdoutLock.lock()
        var off = 0
        while off < n {
            let w = buf.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress! + off, n - off) }
            if w <= 0 { exit(0) }
            off += w
        }
        stdoutLock.unlock()
    }
    lock.lock()
    if appFD == fd { appFD = -1 }
    lock.unlock()
    close(fd)
    reply(offlineStatus(id: nil))
    watchForApp()
}

func offlineStatus(id: Any?) -> [String: Any] {
    var m: [String: Any] = ["type": "status", "ready": false, "offline": true, "appVersion": "",
                            "problem": "VoiceNote Translator isn't running."]
    if let id { m["id"] = id }
    return m
}

/// Polls for the app every 2 seconds until it's back.
func watchForApp() {
    lock.lock()
    if watching { lock.unlock(); return }
    watching = true
    lock.unlock()
    Thread.detachNewThread {
        while !attach() { sleep(2) }
        lock.lock()
        watching = false
        lock.unlock()
    }
}

// MARK: Browser → app

/// Requests the person made may start the app; lookups, status checks and
/// background hellos may not.
let userActions: Set<String> = ["translate", "openSettings"]

func handle(_ msg: [String: Any]) {
    let type = msg["type"] as? String ?? ""
    if type == "hello" {
        lock.lock()
        hello = msg
        lock.unlock()
    }
    if sendToApp(msg) { return }

    // The app isn't reachable.
    let mayStart = userActions.contains(type) || (msg["auto"] as? Bool == false && type != "lookup")
    if mayStart {
        launchApp()
        for _ in 0..<40 {   // up to ~10s for the app to start
            if attach() { break }
            usleep(250_000)
        }
        // attach() already replayed the hello; don't send it twice.
        if type == "hello" {
            lock.lock()
            let up = appFD >= 0
            lock.unlock()
            if up { return }
        } else if sendToApp(msg) {
            return
        }
    }
    switch type {
    case "hello", "status":
        reply(offlineStatus(id: msg["id"]))
    default:
        var e: [String: Any] = ["type": "error",
                                "message": mayStart ? "VoiceNote Translator couldn't be started. Open it from Applications."
                                                    : "VoiceNote Translator isn't running."]
        if let id = msg["id"] { e["id"] = id }
        reply(e)
    }
    watchForApp()
}

if !attach() { watchForApp() }

var decoder = FrameDecoder()
var buf = [UInt8](repeating: 0, count: 256 * 1024)
while true {
    let n = read(STDIN_FILENO, &buf, buf.count)
    if n <= 0 { exit(0) }   // the browser closed the connection
    guard let messages = try? decoder.append(Data(buf[0..<n])) else { exit(1) }
    for m in messages { handle(m) }
}
