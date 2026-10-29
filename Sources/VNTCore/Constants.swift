import Foundation

/// Names and locations shared by the app and the native messaging host.
public enum VNT {
    public static let appName = "VoiceNote Translator"
    public static let bundleID = "io.github.voicenote-translator"

    /// The name browsers know the native messaging host by.
    public static let nativeHostName = "io.github.voicenote_translator"

    /// Extensions allowed to connect. The first is the ID the bundled extension
    /// always gets (its manifest carries a fixed public key). Add your Chrome Web
    /// Store ID here if you publish the extension there.
    public static let allowedExtensionIDs = ["fkilpaihgimacikajfnnflklnbonfllo"]

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static var socketPath: String { supportDirectory.appendingPathComponent("bridge.sock").path }

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
