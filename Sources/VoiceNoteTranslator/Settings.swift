import Foundation
import Security
import VNTCore

/// User settings, stored in UserDefaults. The API key lives in the Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    static let defaultBaseURL = "https://openrouter.ai/api/v1"
    static let defaultSTTModel = "openai/whisper-large-v3-turbo"
    static let defaultRewordModel = "anthropic/claude-haiku-5.5"

    @Published var targetLanguage: String { didSet { d.set(targetLanguage, forKey: "targetLanguage") } }
    @Published var baseURL: String { didSet { d.set(baseURL, forKey: "baseURL") } }
    @Published var sttModel: String { didSet { d.set(sttModel, forKey: "sttModel") } }
    @Published var rewordModel: String { didSet { d.set(rewordModel, forKey: "rewordModel") } }
    /// Optional: a .env-style file to read the key from instead of the Keychain.
    @Published var keyFile: String { didSet { d.set(keyFile, forKey: "keyFile") } }
    @Published var desktopButtons: Bool { didSet { d.set(desktopButtons, forKey: "desktopButtons") } }
    @Published var rememberTranslations: Bool { didSet { d.set(rememberTranslations, forKey: "rememberTranslations") } }
    /// Bumped whenever the key changes, so views showing key status refresh.
    @Published private(set) var keyRevision = 0

    private init() {
        targetLanguage = d.string(forKey: "targetLanguage") ?? "English"
        baseURL = d.string(forKey: "baseURL") ?? Self.defaultBaseURL
        sttModel = d.string(forKey: "sttModel") ?? Self.defaultSTTModel
        rewordModel = d.string(forKey: "rewordModel") ?? Self.defaultRewordModel
        keyFile = d.string(forKey: "keyFile") ?? ""
        desktopButtons = d.object(forKey: "desktopButtons") as? Bool ?? true
        rememberTranslations = d.object(forKey: "rememberTranslations") as? Bool ?? true
    }

    func resetModels() {
        baseURL = Self.defaultBaseURL
        sttModel = Self.defaultSTTModel
        rewordModel = Self.defaultRewordModel
    }

    // MARK: API key

    enum KeySource: String { case keychain = "Keychain", file = "Key file", environment = "Environment", none = "Not set" }

    /// Where the key comes from: the Keychain first, then the key file, then the environment.
    func apiKey() -> (key: String?, source: KeySource) {
        if let k = Keychain.read(), !k.isEmpty { return (k, .keychain) }
        if !keyFile.isEmpty, let k = Self.readKeyFile((keyFile as NSString).expandingTildeInPath) { return (k, .file) }
        let env = ProcessInfo.processInfo.environment
        if let k = env["OPENROUTER_API_KEY"] ?? env["OPENAI_API_KEY"], !k.isEmpty { return (k, .environment) }
        return (nil, .none)
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete() } else { Keychain.save(trimmed) }
        keyRevision += 1
    }

    /// Reads the first `*_API_KEY=` line of a .env-style file.
    static func readKeyFile(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "="), line[..<eq].hasSuffix("API_KEY") else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty { return value }
        }
        return nil
    }
}

enum Keychain {
    private static let service = VNT.bundleID
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
