import Foundation

struct GroqModel: Decodable, Hashable {
    let id: String
    let active: Bool?
}

/// Error HTTP devuelto por la API de Groq.
struct GroqAPIError: LocalizedError {
    let statusCode: Int
    let message: String
    let retryAfter: TimeInterval?
    let rawResponse: String

    var errorDescription: String? {
        switch statusCode {
        case 401:
            return "Groq rechazó la API key (401): \(message)"
        case 413:
            return "La petición es demasiado grande para este modelo o plan (413): \(message)"
        case 429:
            return "Límite de uso de Groq alcanzado (429): \(message)"
        default:
            return "Groq respondió \(statusCode): \(message)"
        }
    }

    var isRetryable: Bool { statusCode == 429 || statusCode >= 500 }
}

/// Petición de chat ya construida, junto con su representación HTTP literal.
struct PreparedChatRequest {
    let urlRequest: URLRequest
    let rawText: String
}

struct ChatResult {
    let content: String
    let rawResponse: String
}

/// Cliente mínimo de la API compatible con OpenAI de Groq.
struct GroqClient {
    static let host = "api.groq.com"
    static let modelsURL = URL(string: "https://api.groq.com/openai/v1/models")!
    static let transcriptionsURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let chatURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1800
        return URLSession(configuration: configuration)
    }()

    let apiKey: String

    // MARK: Modelos

    func listModels() async throws -> [GroqModel] {
        var request = URLRequest(url: Self.modelsURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(data: data, response: response)
        struct ModelList: Decodable { let data: [GroqModel] }
        return try JSONDecoder().decode(ModelList.self, from: data).data
    }

    // MARK: Transcripción

    func transcribe(fileURL: URL, model: String, language: String?) async throws -> String {
        let audio = try Data(contentsOf: fileURL)
        let boundary = "MeetingAssistant-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField("model", model)
        appendField("response_format", "json")
        appendField("temperature", "0")
        if let language, !language.isEmpty {
            appendField("language", language)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: Self.transcriptionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await Self.session.upload(for: request, from: body)
        try Self.validate(data: data, response: response)
        struct Transcription: Decodable { let text: String }
        return try JSONDecoder().decode(Transcription.self, from: data).text
    }

    // MARK: Chat

    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
    }

    /// Construye la petición sin enviarla, para poder guardar el request raw antes de mandarlo.
    func prepareChat(model: String, messages: [ChatMessage], temperature: Double = 0.3) throws -> PreparedChatRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(ChatBody(model: model, messages: messages, temperature: temperature))

        var request = URLRequest(url: Self.chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let raw = [
            "POST \(Self.chatURL.path) HTTP/1.1",
            "Host: \(Self.host)",
            "Authorization: Bearer \(Self.redacted(apiKey))",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "",
            String(decoding: body, as: UTF8.self),
        ].joined(separator: "\n")

        return PreparedChatRequest(urlRequest: request, rawText: raw)
    }

    func send(_ prepared: PreparedChatRequest) async throws -> ChatResult {
        let (data, response) = try await Self.session.data(for: prepared.urlRequest)
        let raw = Self.rawResponse(data: data, response: response)
        try Self.validate(data: data, response: response, raw: raw)

        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let completion = try JSONDecoder().decode(Completion.self, from: data)
        let content = Self.stripReasoning(completion.choices.first?.message.content ?? "")
        guard !content.isEmpty else {
            throw GroqAPIError(statusCode: 200, message: "El modelo devolvió una respuesta vacía.", retryAfter: nil, rawResponse: raw)
        }
        return ChatResult(content: content, rawResponse: raw)
    }

    // MARK: Utilidades

    static func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? GroqAPIError {
            return apiError.isRetryable
        }
        if let urlError = error as? URLError {
            let transient: [URLError.Code] = [
                .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                .callIsActive, .secureConnectionFailed, .resourceUnavailable, .backgroundSessionWasDisconnected,
            ]
            return transient.contains(urlError.code)
        }
        return false
    }

    /// Espera antes del siguiente intento (respeta `retry-after` cuando Groq lo envía).
    static func retryDelay(for error: Error, attempt: Int) -> TimeInterval {
        if let apiError = error as? GroqAPIError, let retryAfter = apiError.retryAfter {
            return min(max(retryAfter, 1), 120)
        }
        return min(pow(3, Double(attempt)), 60)
    }

    static func redacted(_ key: String) -> String {
        guard key.count > 8 else { return "••••" }
        return "\(key.prefix(4))••••\(key.suffix(4))"
    }

    /// Algunos modelos de razonamiento devuelven `<think>…</think>` dentro del contenido.
    static func stripReasoning(_ content: String) -> String {
        content
            .replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rawResponse(data: Data, response: URLResponse) -> String {
        var lines: [String] = []
        if let http = response as? HTTPURLResponse {
            lines.append("HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
            let headers = http.allHeaderFields
                .map { (String(describing: $0.key), String(describing: $0.value)) }
                .sorted { $0.0.lowercased() < $1.0.lowercased() }
            for (name, value) in headers {
                lines.append("\(name): \(value)")
            }
        }
        lines.append("")
        lines.append(prettyJSON(data) ?? String(decoding: data, as: UTF8.self))
        return lines.joined(separator: "\n")
    }

    private static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    private static func validate(data: Data, response: URLResponse, raw: String? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GroqAPIError(statusCode: -1, message: "Respuesta no válida.", retryAfter: nil,
                               rawResponse: raw ?? String(decoding: data, as: UTF8.self))
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = errorMessage(from: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap { TimeInterval($0) }
            throw GroqAPIError(statusCode: http.statusCode, message: message, retryAfter: retryAfter,
                               rawResponse: raw ?? rawResponse(data: data, response: response))
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct Body: Decodable { let message: String? }
            let error: Body?
        }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message, !message.isEmpty {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }
}
