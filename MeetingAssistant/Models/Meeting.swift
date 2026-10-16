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
    /// Pedida: se generará cuando terminen los resúmenes o la pausa por cuota.
    case queued
    case generating
    case done
    case failed
}

/// Resumen de uno o varios bloques consecutivos (o, en modo acumulativo, el resumen
/// acumulado después de procesar ese bloque).
struct SegmentSummary: Codable, Hashable {
    var chunkIndices: [Int]
    var text: String
    var createdAt: Date
    var model: String?
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
    /// Plan con el que se generaron `segmentSummaries`; si cambia, se descartan.
    var summaryPlan: SummaryPlan?
    var segmentSummaries: [SegmentSummary]?
    /// Error que detuvo la generación de resúmenes de esta reunión.
    var summaryError: String?

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
        !isRecording && !isTranscribing && minutesStatus != .generating && minutesStatus != .queued
            && !combinedTranscript.isEmpty
    }

    // MARK: Resúmenes

    var summaries: [SegmentSummary] {
        (segmentSummaries ?? []).sorted { ($0.chunkIndices.first ?? 0) < ($1.chunkIndices.first ?? 0) }
    }

    /// Índices de los bloques que ya forman parte de algún resumen (procesados en la nube).
    var summarizedIndices: Set<Int> {
        Set((segmentSummaries ?? []).flatMap(\.chunkIndices))
    }

    func isSummarized(_ chunk: AudioChunk) -> Bool {
        summarizedIndices.contains(chunk.index)
    }

    /// Grupos de bloques consecutivos de `size` bloques (el último puede estar incompleto).
    func chunkGroups(size: Int) -> [[Int]] {
        let size = max(size, 1)
        let grouped = Dictionary(grouping: chunks.map(\.index)) { $0 / size }
        return grouped.keys.sorted().map { grouped[$0, default: []].sorted() }
    }

    /// Segmentos resumidos y totales según el plan (los resúmenes de otro plan no cuentan).
    func summaryProgress(for plan: SummaryPlan) -> (done: Int, total: Int) {
        guard plan.mode.usesSummaries else { return (0, 0) }
        let current = summaryPlan == plan ? (segmentSummaries ?? []) : []
        switch plan.mode {
        case .fullTranscript:
            return (0, 0)
        case .iterative:
            let processed = Set(current.flatMap(\.chunkIndices))
            return (chunks.filter { processed.contains($0.index) }.count, chunks.count)
        case .perChunk, .mapReduce:
            let groups = chunkGroups(size: plan.groupSize)
            let done = groups.filter { group in current.contains { $0.chunkIndices == group } }.count
            return (done, groups.count)
        }
    }

    func summariesComplete(for plan: SummaryPlan) -> Bool {
        let progress = summaryProgress(for: plan)
        return progress.total > 0 && progress.done == progress.total
    }

    /// Texto que se envía después del prompt de la minuta según la forma de procesar.
    func minutesInput(for plan: SummaryPlan) -> String {
        switch plan.mode {
        case .fullTranscript:
            return combinedTranscript
        case .perChunk, .mapReduce:
            let parts = summaries.map { summary -> String in
                let first = summary.chunkIndices.first ?? 0
                let last = summary.chunkIndices.last ?? first
                let label = first == last ? "Bloque \(first + 1)" : "Bloques \(first + 1)–\(last + 1)"
                return "\(label):\n\(summary.text)"
            }
            return AppSettings.summariesNote + "\n\n"
                + parts.joined(separator: "\n\n\(AppSettings.summaryBoundary)\n\n")
        case .iterative:
            return AppSettings.iterativeNote + "\n\n" + (summaries.last?.text ?? "")
        }
    }

    /// Segundo de la grabación en el que empieza el bloque.
    func startOffset(of chunk: AudioChunk) -> TimeInterval {
        chunks.filter { $0.index < chunk.index }.reduce(0) { $0 + $1.duration }
    }
}
