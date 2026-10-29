import Foundation

struct Translation: Codable, Equatable {
    var transcript: String
    var text: String
    var language: String
}

struct TranslatorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Talks to an OpenAI-compatible API (OpenRouter by default): speech-to-text,
/// then a chat model that translates and rewords the transcript.
struct Translator {
    let baseURL: URL
    let apiKey: String
    let sttModel: String
    let rewordModel: String
    let targetLanguage: String

    enum Stage: String { case transcribing, translating }

    static func prompt(_ lang: String) -> String {
        """
        You are a translator. You get the raw speech-to-text transcript of a voice message, in any language. Speech recognition may have garbled some words.
        Translate it into \(lang), whatever language it is in, and reword it as clear, natural \(lang) that keeps the speaker's meaning, tone and every point they make. The output must be written in \(lang), never in the source language. Write it as the speaker (first person), not as a summary. Keep names, numbers and greetings such as "mashallah". Fix obvious recognition errors from context; if a part is truly unclear, give your best reading and mark it with [unclear].
        Reply with JSON only: {"language": "<language the speaker used, named in English>", "text": "<the \(lang) translation>"}
        """
    }

    func run(audio: Data, mime: String, progress: (Stage) -> Void = { _ in }) async throws -> Translation {
        progress(.transcribing)
        let transcript = try await transcribe(audio: audio, mime: mime)
        if transcript.isEmpty { return Translation(transcript: "", text: "(No speech detected.)", language: "") }
        progress(.translating)
        return try await reword(transcript)
    }

    func transcribe(audio: Data, mime: String) async throws -> String {
        let type = mime.split(separator: ";").first.map(String.init) ?? "audio/ogg"
        let ext = type.split(separator: "/").last.map { $0 == "mpeg" ? "mp3" : String($0) } ?? "ogg"
        let boundary = "vnt-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(sttModel)\r\n")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.\(ext)\"\r\nContent-Type: \(type)\r\n\r\n")
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n")

        var req = request("audio/transcriptions")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let json = try await send(req)
        return ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reword(_ transcript: String) async throws -> Translation {
        var req = request("chat/completions")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": rewordModel,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": Self.prompt(targetLanguage)],
                ["role": "user", "content": "Transcript:\n\(transcript)\n\nTranslate into \(targetLanguage)."],
            ],
        ])
        let json = try await send(req)
        let content = (((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var language = ""
        if let s = content.firstIndex(of: "{"), let e = content.lastIndex(of: "}"),
           let obj = try? JSONSerialization.jsonObject(with: Data(content[s...e].utf8)) as? [String: Any] {
            text = (obj["text"] as? String) ?? text
            language = (obj["language"] as? String) ?? ""
        }
        return Translation(transcript: transcript, text: text, language: language)
    }

    /// A cheap call that proves the key and base URL work.
    func check() async throws {
        var req = request("models")
        req.httpMethod = "GET"
        req.httpBody = nil
        _ = try await send(req)
        // /models is public on some providers; /key confirms the key on OpenRouter.
        if baseURL.host?.contains("openrouter") == true {
            var keyReq = request("key")
            keyReq.httpMethod = "GET"
            _ = try await send(keyReq)
        }
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("https://github.com/noorfrhx/voicenote-translator", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("VoiceNote Translator", forHTTPHeaderField: "X-Title")
        return req
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw TranslatorError("Couldn't reach \(baseURL.host ?? "the API"): \(error.localizedDescription)") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw TranslatorError("The API rejected the key. Check it in Settings → Translation.") }
        guard (200..<300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? (json["message"] as? String)
            throw TranslatorError(message ?? "The API returned error \(status).")
        }
        return json
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
