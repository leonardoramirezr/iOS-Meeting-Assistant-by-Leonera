import Foundation

enum ChunkStatus: String, Codable {
    case pending
    case transcribing
    case done
    case failed
}

/// Un clip de audio de la grabación, transcrito de forma independiente.
struct AudioChunk: Codable, Identifiable, Hashable {
    var index: Int
    var fileName: String
    var duration: TimeInterval
    var status: ChunkStatus = .pending
    var transcript: String?
    var error: String?
    var model: String?

    var id: Int { index }
}

enum MinutesStatus: String, Codable {
    case none
    case generating
    case done
    case failed
}

/// Copia literal de la última petición HTTP enviada al LLM y de su respuesta.
struct LLMExchange: Codable, Hashable {
    var date: Date
    var model: String
    var request: String
    var response: String?
}

struct Meeting: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval = 0
    var isRecording: Bool = false
    var chunkDuration: TimeInterval
    var chunks: [AudioChunk] = []
    var minutes: String?
    var minutesStatus: MinutesStatus = .none
    var minutesError: String?
    var minutesModel: String?
    var minutesGeneratedAt: Date?
    var lastLLMExchange: LLMExchange?

    var transcribedCount: Int { chunks.filter { $0.status == .done }.count }
    var failedCount: Int { chunks.filter { $0.status == .failed }.count }

    /// Hay bloques esperando turno o subiéndose a Whisper.
    var isTranscribing: Bool {
        chunks.contains { $0.status == .pending || $0.status == .transcribing }
    }

    var allChunksTranscribed: Bool {
        !chunks.isEmpty && chunks.allSatisfy { $0.status == .done }
    }

    /// Transcripciones de los bloques en orden, separadas por `[TRANSCRIPTION CHUNK BOUNDARY]`.
    var combinedTranscript: String {
        chunks
            .sorted { $0.index < $1.index }
            .compactMap { chunk -> String? in
                guard chunk.status == .done,
                      let text = chunk.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return text
            }
            .joined(separator: "\n\n\(AppSettings.chunkBoundary)\n\n")
    }

    var canGenerateMinutes: Bool {
        !isRecording && !isTranscribing && minutesStatus != .generating && !combinedTranscript.isEmpty
    }

    /// Segundo de la grabación en el que empieza el bloque.
    func startOffset(of chunk: AudioChunk) -> TimeInterval {
        chunks.filter { $0.index < chunk.index }.reduce(0) { $0 + $1.duration }
    }
}
