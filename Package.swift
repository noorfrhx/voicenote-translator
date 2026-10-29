// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceNoteTranslator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceNoteTranslator", targets: ["VoiceNoteTranslator"]),
        .executable(name: "vnt-host", targets: ["vnt-host"]),
    ],
    dependencies: [
        // Automatic updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.10.1")),
    ],
    targets: [
        // Shared by the app and the native messaging host: framing, protocol, paths.
        .target(name: "VNTCore", path: "Sources/VNTCore"),
        // The menu bar app: translation, settings, history, browser bridge, WhatsApp Desktop buttons, updates.
        .executableTarget(
            name: "VoiceNoteTranslator",
            dependencies: ["VNTCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/VoiceNoteTranslator",
            // Sparkle.framework is copied into Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Started by Chrome for the extension; relays messages to the running app.
        .executableTarget(name: "vnt-host", dependencies: ["VNTCore"], path: "Sources/vnt-host"),
        .testTarget(name: "VNTCoreTests", dependencies: ["VNTCore"], path: "Tests/VNTCoreTests"),
    ]
)
