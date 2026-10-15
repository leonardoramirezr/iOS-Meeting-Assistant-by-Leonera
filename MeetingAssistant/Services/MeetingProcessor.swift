import Foundation
import Observation

/// Cola de transcripción (Whisper), de resúmenes por segmento y de generación de minutas (LLM).
@MainActor
@Observable
final class MeetingProcessor {
    private(set) var isProcessingQueue = false
    private(set) var isSummarizing = false
    /// Último rechazo de la API key de cada proveedor; su cola se detiene hasta que la key cambie.
    private(set) var authErrors: [LLMProvider: String] = [:]
    /// Fin de la pausa por límite de cuota (429). Se guarda para reanudar tras reiniciar la app.
    private(set) var pausedUntil: Date? = nil
    /// Motivo de la pausa en curso (cuota agotada o pausa preventiva).
    private(set) var pauseReason: String? = nil
    @ObservationIgnored private var apiKeys: [LLMProvider: String] = [:]
    @ObservationIgnored private var resumeTask: Task<Void, Never>? = nil
    @ObservationIgnored private var generatingMinutes: Set<UUID> = []

    private let store: MeetingStore
    private let maxAttempts = 4

    init(store: MeetingStore) {
        self.store = store
        if let until = AppSettings.pausedUntil, until > Date() {
            pausedUntil = until
            pauseReason = AppSettings.pauseReason
            scheduleResume(at: until)
        } else {
            AppSettings.pausedUntil = nil
            AppSettings.pauseReason = nil
        }
    }

    func updateAPIKey(_ key: String, for provider: LLMProvider) {
        if key != apiKeys[provider, default: ""] {
            apiKeys[provider] = key
            authErrors[provider] = nil
        }
        kick()
    }

    private func key(for provider: LLMProvider) -> String {
        apiKeys[provider, default: ""]
    }

    private func hasUsableKey(_ provider: LLMProvider) -> Bool {
        !key(for: provider).isEmpty && authErrors[provider] == nil
    }

    /// La transcripción (Whisper) siempre va a Groq.
    private var canTranscribe: Bool { hasUsableKey(.groq) }

    /// Resúmenes y minuta usan el proveedor de LLM seleccionado.
    private var canUseLLM: Bool { hasUsableKey(AppSettings.llmProvider) }

    private func llmClient() -> GroqClient {
        let provider = AppSettings.llmProvider
        return GroqClient(apiKey: key(for: provider), provider: provider)
    }

    private func markAuthError(_ error: GroqAPIError) {
        authErrors[error.provider] = error.localizedDescription
    }

    var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }

    // MARK: Arranque de las colas

    /// Reanuda todo lo pendiente: transcripciones, resúmenes y minutas en cola.
    /// Se llama al abrir la app, al cambiar la API key y cuando termina una pausa.
    func kick() {
        clearExpiredPause()
        guard !isPaused else { return }
        kickTranscription()
        kickSummaries()
        for meeting in store.meetings where meeting.minutesStatus == .queued {
            checkCompletion(meeting.id)
        }
    }

    private func kickTranscription() {
        guard !isProcessingQueue, canTranscribe, !isPaused, store.nextPendingChunk() != nil else { return }
        isProcessingQueue = true
        Task {
            await drainQueue()
        }
    }

    // MARK: Pausa por cuota

    private func pauseForQuota(_ error: GroqAPIError) {
        let delay = max(AppSettings.quotaPause, error.retryAfter ?? 0)
        pause(for: delay, reason: "En pausa por límite de cuota de Groq")
    }

    /// Pausa preventiva: la respuesta indica que quedan pocos tokens en la ventana actual.
    /// Se espera a que el límite se restablezca (`x-ratelimit-reset-tokens`) o, si Groq no
    /// lo indica, el tiempo de pausa configurado.
    private func checkRateLimit(_ info: RateLimitInfo?) {
        guard AppSettings.preventiveRateLimitPause, let info,
              info.remainingTokens <= AppSettings.rateLimitTokenThreshold else { return }
        let delay = max(info.resetTokens ?? AppSettings.quotaPause, 1)
        pause(for: delay, reason: "Pausa preventiva: quedan \(info.remainingTokens) tokens en el límite de Groq")
    }

    private func pause(for delay: TimeInterval, reason: String) {
        let until = Date().addingTimeInterval(delay)
        if let current = pausedUntil, current > until { return }
        pausedUntil = until
        pauseReason = reason
        AppSettings.pausedUntil = until
        AppSettings.pauseReason = reason
        scheduleResume(at: until)
    }

    /// Termina la pausa ya (botón "Reanudar ahora").
    func resumeNow() {
        resumeTask?.cancel()
        resumeTask = nil
        pausedUntil = nil
        pauseReason = nil
        AppSettings.pausedUntil = nil
        AppSettings.pauseReason = nil
        kick()
    }

    private func clearExpiredPause() {
        if let pausedUntil, pausedUntil <= Date() {
            self.pausedUntil = nil
            pauseReason = nil
            AppSettings.pausedUntil = nil
            AppSettings.pauseReason = nil
        }
    }

    private func scheduleResume(at date: Date) {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            let seconds = max(date.timeIntervalSinceNow, 0) + 0.5
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Si el sistema suspendió la app, esto corre al volver; `kick()` al entrar
            // a la app también reanuda si la pausa ya venció.
            self?.kick()
        }
    }

    private static func isQuotaError(_ error: Error) -> GroqAPIError? {
        guard let apiError = error as? GroqAPIError, apiError.statusCode == 429 else { return nil }
        return apiError
    }

    // MARK: Transcripción

    func retryChunk(_ meetingID: UUID, index: Int) {
        store.updateChunk(meetingID, index: index) { chunk in
            chunk.status = .pending
            chunk.error = nil
        }
        kick()
    }

    func retryFailedChunks(_ meetingID: UUID) {
        guard let meeting = store.meeting(meetingID) else { return }
        for chunk in meeting.chunks where chunk.status == .failed {
            store.updateChunk(meetingID, index: chunk.index) { chunk in
                chunk.status = .pending
                chunk.error = nil
            }
        }
        kick()
    }

    private func drainQueue() async {
        let activity = BackgroundActivity(name: "transcription")
        defer { activity.end() }
        while canTranscribe, !isPaused, let job = store.nextPendingChunk() {
            await transcribe(job)
        }
        // Sin `await` entre la última comprobación y aquí: `kick()` no puede colarse.
        isProcessingQueue = false
    }

    private func transcribe(_ job: ChunkJob) async {
        let groqKey = key(for: .groq)
        let model = AppSettings.transcriptionModel
        let language = AppSettings.transcriptionLanguage
        store.updateChunk(job.meetingID, index: job.index) { chunk in
            chunk.status = .transcribing
            chunk.error = nil
        }

        guard FileManager.default.fileExists(atPath: job.fileURL.path) else {
            store.updateChunk(job.meetingID, index: job.index) { chunk in
                chunk.status = .failed
                chunk.error = "No se encontró el archivo de audio."
            }
            kickSummaries()
            return
        }

        let client = GroqClient(apiKey: groqKey)
        var attempt = 0
        while true {
            attempt += 1
            do {
                let result = try await client.transcribe(fileURL: job.fileURL, model: model, language: language)
                checkRateLimit(result.rateLimit)
                store.updateChunk(job.meetingID, index: job.index) { chunk in
                    chunk.status = .done
                    chunk.transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    chunk.error = nil
                    chunk.model = model
                }
                invalidateSummaries(job.meetingID, containing: job.index)
                kickSummaries()
                checkCompletion(job.meetingID)
                return
            } catch let error as GroqAPIError where error.isAuthError {
                // Con la key rechazada no tiene sentido seguir: el bloque vuelve a la cola.
                markAuthError(error)
                store.updateChunk(job.meetingID, index: job.index) { chunk in
                    chunk.status = .pending
                    chunk.error = error.localizedDescription
                }
                return
            } catch {
                if let quotaError = Self.isQuotaError(error) {
                    // Límite de cuota: el bloque vuelve a la cola y todo se pausa.
                    store.updateChunk(job.meetingID, index: job.index) { chunk in
                        chunk.status = .pending
                        chunk.error = "En pausa por límite de cuota de Groq."
                    }
                    pauseForQuota(quotaError)
                    return
                }
                if GroqClient.isRetryable(error), attempt < maxAttempts {
                    let delay = GroqClient.retryDelay(for: error, attempt: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                store.updateChunk(job.meetingID, index: job.index) { chunk in
                    chunk.status = .failed
                    chunk.error = error.localizedDescription
                }
                kickSummaries()
                return
            }
        }
    }

    // MARK: Resúmenes

    private enum SummaryJob {
        /// Resumen de un bloque o de un grupo de bloques (Resumir cada bloque / Map-Reduce).
        case segment(meetingID: UUID, indices: [Int])
        /// Siguiente paso del resumen acumulativo.
        case iterative(meetingID: UUID, index: Int)

        var meetingID: UUID {
            switch self {
            case let .segment(meetingID, _), let .iterative(meetingID, _): return meetingID
            }
        }
    }

    /// Una reunión participa en los resúmenes mientras su minuta no esté hecha
    /// (o cuando se pidió regenerarla).
    private func needsSummaries(_ meeting: Meeting) -> Bool {
        meeting.minutesStatus != .done && meeting.minutesStatus != .generating && meeting.summaryError == nil
    }

    /// Si la forma de procesar cambió, descarta los resúmenes de la reunión para empezar de nuevo.
    private func syncPlan(_ meetingID: UUID, plan: SummaryPlan) {
        guard let meeting = store.meeting(meetingID), meeting.summaryPlan != plan else { return }
        store.update(meetingID) { meeting in
            meeting.summaryPlan = plan
            meeting.segmentSummaries = []
            meeting.summaryError = nil
        }
    }

    /// Un bloque "asentado" ya no cambiará: está transcrito o falló.
    private static func isSettled(_ chunk: AudioChunk) -> Bool {
        chunk.status == .done || chunk.status == .failed
    }

    private func nextSummaryJob() -> SummaryJob? {
        let plan = AppSettings.summaryPlan
        guard plan.mode.usesSummaries else { return nil }
        let ordered = store.meetings.sorted { lhs, rhs in
            if lhs.isRecording != rhs.isRecording { return lhs.isRecording }
            return lhs.createdAt < rhs.createdAt
        }
        for candidate in ordered where needsSummaries(candidate) && !candidate.chunks.isEmpty {
            syncPlan(candidate.id, plan: plan)
            guard let meeting = store.meeting(candidate.id) else { continue }
            let existing = meeting.segmentSummaries ?? []
            let chunksByIndex = Dictionary(uniqueKeysWithValues: meeting.chunks.map { ($0.index, $0) })

            switch plan.mode {
            case .fullTranscript:
                return nil
            case .perChunk, .mapReduce:
                for group in meeting.chunkGroups(size: plan.groupSize) {
                    if existing.contains(where: { $0.chunkIndices == group }) { continue }
                    // Un grupo incompleto solo se resume cuando la grabación terminó.
                    let isFull = group.count == plan.groupSize
                    guard isFull || !meeting.isRecording else { continue }
                    let settled = group.allSatisfy { chunksByIndex[$0].map(Self.isSettled) ?? false }
                    if settled {
                        return .segment(meetingID: meeting.id, indices: group)
                    }
                }
            case .iterative:
                let processed = Set(existing.flatMap(\.chunkIndices))
                // Estrictamente en orden cronológico: se espera al siguiente bloque sin procesar.
                if let next = meeting.chunks.sorted(by: { $0.index < $1.index })
                    .first(where: { !processed.contains($0.index) }),
                   Self.isSettled(next) {
                    return .iterative(meetingID: meeting.id, index: next.index)
                }
            }
        }
        return nil
    }

    func kickSummaries() {
        guard !isSummarizing, canUseLLM, !isPaused, nextSummaryJob() != nil else { return }
        isSummarizing = true
        Task {
            await drainSummaries()
        }
    }

    private func drainSummaries() async {
        let activity = BackgroundActivity(name: "summaries")
        defer { activity.end() }
        while canUseLLM, !isPaused, let job = nextSummaryJob() {
            await run(job)
            checkCompletion(job.meetingID)
        }
        isSummarizing = false
    }

    /// Reintenta los resúmenes de una reunión después de un error.
    func retrySummaries(_ meetingID: UUID) {
        store.update(meetingID) { meeting in
            meeting.summaryError = nil
        }
        kick()
    }

    /// Un bloque que se transcribió después de haberse resumido (p. ej. tras reintentarlo)
    /// invalida los resúmenes que lo incluyen; en modo acumulativo, también los posteriores.
    private func invalidateSummaries(_ meetingID: UUID, containing index: Int) {
        guard let meeting = store.meeting(meetingID),
              let summaries = meeting.segmentSummaries, !summaries.isEmpty else { return }
        let remaining: [SegmentSummary]
        if meeting.summaryPlan?.mode == .iterative {
            remaining = summaries.filter { ($0.chunkIndices.max() ?? 0) < index }
        } else {
            remaining = summaries.filter { !$0.chunkIndices.contains(index) }
        }
        guard remaining.count != summaries.count else { return }
        store.update(meetingID) { meeting in
            meeting.segmentSummaries = remaining
        }
    }

    private func transcriptText(_ meeting: Meeting, indices: [Int]) -> String {
        meeting.chunks
            .filter { indices.contains($0.index) && $0.status == .done }
            .sorted { $0.index < $1.index }
            .compactMap { chunk -> String? in
                let text = (chunk.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n\n\(AppSettings.chunkBoundary)\n\n")
    }

    private func rangeLabel(_ meeting: Meeting, indices: [Int]) -> String {
        let chunks = meeting.chunks.filter { indices.contains($0.index) }.sorted { $0.index < $1.index }
        guard let first = chunks.first, let last = chunks.last else { return "" }
        let start = meeting.startOffset(of: first)
        let end = meeting.startOffset(of: last) + last.duration
        let blocks = first.index == last.index
            ? "bloque \(first.index + 1)"
            : "bloques \(first.index + 1)–\(last.index + 1)"
        return "\(blocks), \(Format.clock(start))–\(Format.clock(end))"
    }

    private func run(_ job: SummaryJob) async {
        guard let meeting = store.meeting(job.meetingID), let plan = meeting.summaryPlan else { return }
        let indices: [Int]
        let message: String
        switch job {
        case let .segment(_, groupIndices):
            indices = groupIndices
            let text = transcriptText(meeting, indices: indices)
            guard !text.isEmpty else {
                saveSummary(SegmentSummary(chunkIndices: indices, text: "Sin contenido relevante.", createdAt: Date()),
                      in: job.meetingID, plan: plan)
                return
            }
            message = AppSettings.segmentSummaryPrompt
                + "\n\nFragmento (\(rangeLabel(meeting, indices: indices))):\n\n" + text
        case let .iterative(_, index):
            indices = [index]
            let previous = meeting.summaries.last?.text ?? ""
            let text = transcriptText(meeting, indices: indices)
            guard !text.isEmpty else {
                // Bloque sin voz: el resumen acumulado no cambia.
                saveSummary(SegmentSummary(chunkIndices: indices, text: previous, createdAt: Date()),
                      in: job.meetingID, plan: plan)
                return
            }
            message = AppSettings.iterativeSummaryPrompt
                + "\n\nRESUMEN ACUMULADO:\n\n" + (previous.isEmpty ? "(vacío)" : previous)
                + "\n\nSIGUIENTE SEGMENTO (\(rangeLabel(meeting, indices: indices))):\n\n" + text
        }

        let model = AppSettings.llmModel
        let client = llmClient()
        var attempt = 0
        while true {
            attempt += 1
            do {
                let prepared = try client.prepareChat(model: model, messages: [.init(role: "user", content: message)])
                let result = try await client.send(prepared)
                checkRateLimit(result.rateLimit)
                saveSummary(SegmentSummary(chunkIndices: indices, text: result.content, createdAt: Date(), model: model),
                      in: job.meetingID, plan: plan)
                return
            } catch let error as GroqAPIError where error.isAuthError {
                markAuthError(error)
                return
            } catch {
                if let quotaError = Self.isQuotaError(error) {
                    pauseForQuota(quotaError)
                    return
                }
                if GroqClient.isRetryable(error), attempt < maxAttempts {
                    let delay = GroqClient.retryDelay(for: error, attempt: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                store.update(job.meetingID) { meeting in
                    meeting.summaryError = error.localizedDescription
                }
                return
            }
        }
    }

    /// Guarda el resumen si la reunión sigue con el mismo plan (la forma de procesar pudo cambiar mientras tanto).
    private func saveSummary(_ summary: SegmentSummary, in meetingID: UUID, plan: SummaryPlan) {
        guard let meeting = store.meeting(meetingID), meeting.summaryPlan == plan else { return }
        store.update(meetingID) { meeting in
            var summaries = meeting.segmentSummaries ?? []
            summaries.removeAll { $0.chunkIndices == summary.chunkIndices }
            summaries.append(summary)
            meeting.segmentSummaries = summaries
        }
    }

    // MARK: Minuta

    /// Genera la minuta cuando la grabación terminó, todo está transcrito y, según la forma
    /// de procesar, todos los resúmenes están listos. Automática si así se configuró,
    /// o si se pidió antes (`queued`).
    func checkCompletion(_ meetingID: UUID) {
        guard let meeting = store.meeting(meetingID) else { return }
        let wanted = meeting.minutesStatus == .queued
            || (meeting.minutesStatus == .none && AppSettings.autoGenerateMinutes && meeting.allChunksTranscribed)
        guard wanted, !meeting.isRecording, !meeting.isTranscribing, !meeting.combinedTranscript.isEmpty else { return }
        let plan = AppSettings.summaryPlan
        if plan.mode.usesSummaries {
            guard meeting.summaryPlan == plan, meeting.summariesComplete(for: plan) else { return }
        }
        sendMinutes(meetingID, plan: plan)
    }

    /// Botón "Generar minuta" / "Regenerar": si faltan resúmenes o hay pausa, queda en cola.
    func generateMinutes(_ meetingID: UUID) {
        guard let meeting = store.meeting(meetingID),
              meeting.minutesStatus != .generating, !generatingMinutes.contains(meetingID) else { return }
        let provider = AppSettings.llmProvider
        guard !key(for: provider).isEmpty else {
            store.update(meetingID) { meeting in
                meeting.minutesStatus = .failed
                meeting.minutesError = "Configura tu API key de \(provider.label) en Ajustes."
            }
            return
        }
        guard !meeting.combinedTranscript.isEmpty else {
            store.update(meetingID) { meeting in
                meeting.minutesStatus = .failed
                meeting.minutesError = "No hay transcripción para generar la minuta."
            }
            return
        }
        store.update(meetingID) { meeting in
            meeting.minutesStatus = .queued
            meeting.minutesError = nil
            meeting.summaryError = nil
        }
        kick()
    }

    private func sendMinutes(_ meetingID: UUID, plan: SummaryPlan) {
        guard let meeting = store.meeting(meetingID), !generatingMinutes.contains(meetingID) else { return }
        guard canUseLLM, !isPaused else {
            store.update(meetingID) { meeting in
                meeting.minutesStatus = .queued
            }
            return
        }

        let model = AppSettings.llmModel
        let client = llmClient()
        let message = AppSettings.minutesPrompt + "\n\n" + meeting.minutesInput(for: plan)
        let prepared: PreparedChatRequest
        do {
            prepared = try client.prepareChat(model: model, messages: [.init(role: "user", content: message)])
        } catch {
            store.update(meetingID) { meeting in
                meeting.minutesStatus = .failed
                meeting.minutesError = error.localizedDescription
            }
            return
        }

        generatingMinutes.insert(meetingID)
        store.update(meetingID) { meeting in
            meeting.minutesStatus = .generating
            meeting.minutesError = nil
            meeting.lastLLMExchange = LLMExchange(date: Date(), model: model, request: prepared.rawText, response: nil)
        }

        Task {
            let activity = BackgroundActivity(name: "minutes")
            defer {
                activity.end()
                generatingMinutes.remove(meetingID)
            }
            var attempt = 0
            while true {
                attempt += 1
                do {
                    let result = try await client.send(prepared)
                    checkRateLimit(result.rateLimit)
                    store.update(meetingID) { meeting in
                        meeting.minutes = result.content
                        meeting.minutesStatus = .done
                        meeting.minutesModel = "\(model) (\(client.provider.label))"
                        meeting.minutesGeneratedAt = Date()
                        meeting.lastLLMExchange?.response = result.rawResponse
                    }
                    return
                } catch {
                    let raw = (error as? GroqAPIError)?.rawResponse
                    if let authError = error as? GroqAPIError, authError.isAuthError {
                        markAuthError(authError)
                    }
                    if let quotaError = Self.isQuotaError(error) {
                        // Se vuelve a intentar sola al terminar la pausa.
                        store.update(meetingID) { meeting in
                            meeting.minutesStatus = .queued
                            meeting.minutesError = quotaError.localizedDescription
                            if let raw { meeting.lastLLMExchange?.response = raw }
                        }
                        pauseForQuota(quotaError)
                        return
                    }
                    if GroqClient.isRetryable(error), attempt < 3 {
                        let delay = GroqClient.retryDelay(for: error, attempt: attempt)
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    store.update(meetingID) { meeting in
                        meeting.minutesStatus = .failed
                        meeting.minutesError = error.localizedDescription
                        if let raw { meeting.lastLLMExchange?.response = raw }
                    }
                    return
                }
            }
        }
    }
}
