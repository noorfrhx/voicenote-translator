// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceNoteTranslator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceNoteTranslator", targets: ["VoiceNoteTranslator"]),
        .executable(name: "vnt-host", targets: ["vnt-host"]),
    ],
    targets: [
        // Shared by the app and the native messaging host: framing, protocol, paths.
        .target(name: "VNTCore", path: "Sources/VNTCore"),
        // The menu bar app: translation, settings, history, browser bridge, WhatsApp Desktop buttons.
        .executableTarget(name: "VoiceNoteTranslator", dependencies: ["VNTCore"], path: "Sources/VoiceNoteTranslator"),
        // Started by Chrome for the extension; relays messages to the running app.
        .executableTarget(name: "vnt-host", dependencies: ["VNTCore"], path: "Sources/vnt-host"),
        .testTarget(name: "VNTCoreTests", dependencies: ["VNTCore"], path: "Tests/VNTCoreTests"),
    ]
)
