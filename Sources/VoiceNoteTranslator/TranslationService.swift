import CryptoKit
import Foundation
import VNTCore

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case web = "WhatsApp Web", desktop = "WhatsApp Desktop" }

    var id = UUID()
    var date = Date()
    var source: Source
    var chat: String?
    var cacheKey: String?
    var audioHash: String
    var translation: Translation
    var targetLanguage: String
}

/// Every translation goes through here, from the browser and from WhatsApp Desktop.
/// It also serves as the cache: a note is only sent to the API once per target language.
@MainActor
final class TranslationService: ObservableObject {
    static let shared = TranslationService()

    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var activeCount = 0
    @Published var lastError: String?

    private let settings = AppSettings.shared
    private var inFlight: [String: Task<Translation, Error>] = [:]
    private let file = VNT.supportDirectory.appendingPathComponent("history.json")
    private let maxEntries = 1000

    private init() { load() }

    func cached(cacheKey: String) -> Translation? {
        history.first { $0.cacheKey == cacheKey && $0.targetLanguage == settings.targetLanguage }?.translation
    }

    func translate(audio: Data, mime: String, cacheKey: String?, source: HistoryEntry.Source, chat: String?,
                   progress: @escaping (Translator.Stage) -> Void = { _ in }) async throws -> (Translation, cached: Bool) {
        let lang = settings.targetLanguage
        let hash = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        if let hit = history.first(where: { ($0.audioHash == hash || ($0.cacheKey != nil && $0.cacheKey == cacheKey)) && $0.targetLanguage == lang }) {
            return (hit.translation, true)
        }
        // The same note clicked twice (or in two places) shares one API call.
        let flightKey = hash + "|" + lang
        if let running = inFlight[flightKey] { return (try await running.value, false) }

        guard let key = settings.apiKey().key else {
            throw TranslatorError("No API key yet. Add one in Settings → Translation.")
        }
        guard let base = URL(string: settings.baseURL.trimmingCharacters(in: .whitespaces)), base.scheme != nil else {
            throw TranslatorError("The API base URL in Settings isn't valid.")
        }
        let translator = Translator(baseURL: base, apiKey: key, sttModel: settings.sttModel,
                                    rewordModel: settings.rewordModel, targetLanguage: lang)
        let task = Task { try await translator.run(audio: audio, mime: mime, progress: progress) }
        inFlight[flightKey] = task
        activeCount += 1
        defer { inFlight[flightKey] = nil; activeCount -= 1 }
        do {
            let t = try await task.value
            record(HistoryEntry(source: source, chat: chat, cacheKey: cacheKey, audioHash: hash, translation: t, targetLanguage: lang))
            lastError = nil
            return (t, false)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: History

    private func record(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > maxEntries { history.removeLast(history.count - maxEntries) }
        save()
    }

    func delete(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    func save() {
        guard settings.rememberTranslations else { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: VNT.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: file, options: [.atomic]) }
    }

    private func load() {
        guard settings.rememberTranslations, let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        history = entries
    }
}
