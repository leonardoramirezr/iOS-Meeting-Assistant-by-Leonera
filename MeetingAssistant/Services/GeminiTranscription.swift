import Foundation

/// Audio a texto con la API nativa de Gemini (`gemini-3.5-transcribe`): el bloque se sube con la
/// Files API (subida reanudable), se transcribe con `models/<modelo>:generateContent` y el archivo
/// se borra de Google al terminar.
extension GroqClient {

    private struct GeminiFile: Decodable {
        let name: String
        let uri: String
        let mimeType: String?
        let state: String?
    }

    func transcribeWithGemini(fileURL: URL, model: String, language: String?) async throws -> TranscriptionResult {
        let uploaded = try await uploadGeminiFile(fileURL)
        do {
            let file = try await waitUntilActive(uploaded)
            let text = try await generateTranscript(file: file, model: model, language: language)
            await deleteGeminiFile(uploaded)
            return TranscriptionResult(text: text, rateLimit: nil)
        } catch {
            await deleteGeminiFile(uploaded)
            throw error
        }
    }

    private func authorizeGemini(_ request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    }

    private func geminiError(_ message: String, statusCode: Int = -1) -> GroqAPIError {
        GroqAPIError(provider: provider, statusCode: statusCode, message: message, retryAfter: nil, rawResponse: "")
    }

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mp3"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return "audio/m4a"
        }
    }

    // MARK: Files API

    /// Subida reanudable: la primera petición devuelve `X-Goog-Upload-URL` y la segunda envía el audio.
    private func uploadGeminiFile(_ fileURL: URL) async throws -> GeminiFile {
        let audio = try Data(contentsOf: fileURL)
        let mimeType = Self.mimeType(for: fileURL)

        var start = URLRequest(url: try url(provider.fileUploadURL))
        start.httpMethod = "POST"
        authorizeGemini(&start)
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(audio.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": fileURL.lastPathComponent]])

        let (startData, startResponse) = try await Self.session.data(for: start)
        try Self.validate(data: startData, response: startResponse, provider: provider)
        guard let uploadURL = (startResponse as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "X-Goog-Upload-URL").flatMap(URL.init(string:)) else {
            throw geminiError("Google no devolvió la URL para subir el audio.", statusCode: 502)
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let (data, response) = try await Self.session.upload(for: upload, from: audio)
        try Self.validate(data: data, response: response, provider: provider)
        struct Envelope: Decodable { let file: GeminiFile }
        return try JSONDecoder().decode(Envelope.self, from: data).file
    }

    /// El audio suele quedar `ACTIVE` al subirlo; si sigue `PROCESSING` se consulta cada 2 s.
    private func waitUntilActive(_ uploaded: GeminiFile) async throws -> GeminiFile {
        var file = uploaded
        var polls = 0
        while file.state == "PROCESSING" {
            polls += 1
            guard polls <= 90 else {
                throw geminiError("Google sigue procesando el audio; se reintentará.", statusCode: 503)
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            var request = URLRequest(url: try url(provider.endpoint(file.name)))
            authorizeGemini(&request)
            let (data, response) = try await Self.session.data(for: request)
            try Self.validate(data: data, response: response, provider: provider)
            file = try JSONDecoder().decode(GeminiFile.self, from: data)
        }
        if file.state == "FAILED" {
            throw geminiError("Google no pudo procesar el archivo de audio.")
        }
        return file
    }

    /// Borrado de cortesía: si falla, Google elimina el archivo solo a las 48 h.
    private func deleteGeminiFile(_ file: GeminiFile) async {
        guard let fileURL = provider.endpoint(file.name) else { return }
        var request = URLRequest(url: fileURL)
        request.httpMethod = "DELETE"
        authorizeGemini(&request)
        _ = try? await Self.session.data(for: request)
    }

    // MARK: generateContent

    private struct GenerateBody: Encodable {
        struct Content: Encodable {
            struct Part: Encodable {
                struct FileData: Encodable {
                    let fileUri: String
                    let mimeType: String
                }
                let fileData: FileData
            }
            let parts: [Part]
        }
        struct GenerationConfig: Encodable {
            struct AudioTranscriptionConfig: Encodable {
                let languageCodes: [String]
            }
            let audioTranscriptionConfig: AudioTranscriptionConfig
        }
        let contents: [Content]
        let generationConfig: GenerationConfig?
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
                let parts: [Part]?
            }
            let content: Content?
        }
        struct PromptFeedback: Decodable { let blockReason: String? }
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
    }

    private func generateTranscript(file: GeminiFile, model: String, language: String?) async throws -> String {
        // La configuración guarda ISO-639-1 ("es"); Gemini pide BCP-47 ("es-419").
        let languageCode = language.map { code in TranscriptionLanguage(rawValue: code)?.bcp47Code ?? code }
        let fileData = GenerateBody.Content.Part.FileData(fileUri: file.uri, mimeType: file.mimeType ?? "audio/m4a")
        let body = GenerateBody(
            contents: [GenerateBody.Content(parts: [GenerateBody.Content.Part(fileData: fileData)])],
            generationConfig: languageCode.map { code in
                GenerateBody.GenerationConfig(audioTranscriptionConfig: .init(languageCodes: [code]))
            }
        )

        var request = URLRequest(url: try url(provider.generateContentURL(model: model)))
        request.httpMethod = "POST"
        authorizeGemini(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(data: data, response: response, provider: provider)
        let result = try JSONDecoder().decode(GenerateResponse.self, from: data)
        if let reason = result.promptFeedback?.blockReason {
            throw GroqAPIError(provider: provider, statusCode: 200,
                               message: "Google bloqueó la transcripción (\(reason)).", retryAfter: nil,
                               rawResponse: Self.rawResponse(data: data, response: response))
        }
        let parts = result.candidates?.first?.content?.parts ?? []
        return parts.filter { $0.thought != true }.compactMap(\.text).joined()
    }
}
