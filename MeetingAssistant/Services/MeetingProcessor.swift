import Foundation
import Observation

/// Cola de transcripción (Whisper) y generación de minutas (LLM).
@MainActor
@Observable
final class MeetingProcessor {
    private(set) var isProcessingQueue = false
    /// Último rechazo de la API key; la cola se detiene hasta que cambie.
    private(set) var authError: String? = nil
    @ObservationIgnored private var apiKey = ""

    private let store: MeetingStore
    private let maxAttempts = 4

    init(store: MeetingStore) {
        self.store = store
    }

    func updateAPIKey(_ key: String) {
        if key != apiKey {
            apiKey = key
            authError = nil
        }
        kick()
    }

    private var hasUsableKey: Bool {
        !apiKey.isEmpty && authError == nil
    }

    // MARK: Transcripción

    /// Procesa los bloques pendientes, uno a la vez y en orden.
    func kick() {
        guard !isProcessingQueue, hasUsableKey, store.nextPendingChunk() != nil else { return }
        isProcessingQueue = true
        Task {
            await drainQueue()
        }
    }

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
        while hasUsableKey, let job = store.nextPendingChunk() {
            await transcribe(job)
        }
        // Sin `await` entre la última comprobación y aquí: `kick()` no puede colarse.
        isProcessingQueue = false
    }

    private func transcribe(_ job: ChunkJob) async {
        let key = apiKey
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
            return
        }

        let client = GroqClient(apiKey: key)
        var attempt = 0
        while true {
            attempt += 1
            do {
                let text = try await client.transcribe(fileURL: job.fileURL, model: model, language: language)
                store.updateChunk(job.meetingID, index: job.index) { chunk in
                    chunk.status = .done
                    chunk.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    chunk.error = nil
                    chunk.model = model
                }
                checkCompletion(job.meetingID)
                return
            } catch let error as GroqAPIError where error.statusCode == 401 {
                // Con la key rechazada no tiene sentido seguir: el bloque vuelve a la cola.
                authError = error.localizedDescription
                store.updateChunk(job.meetingID, index: job.index) { chunk in
                    chunk.status = .pending
                    chunk.error = error.localizedDescription
                }
                return
            } catch {
                if GroqClient.isRetryable(error), attempt < maxAttempts {
                    let delay = GroqClient.retryDelay(for: error, attempt: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                store.updateChunk(job.meetingID, index: job.index) { chunk in
                    chunk.status = .failed
                    chunk.error = error.localizedDescription
                }
                return
            }
        }
    }

    /// Genera la minuta automáticamente cuando la grabación terminó y todos los bloques están transcritos.
    func checkCompletion(_ meetingID: UUID) {
        guard AppSettings.autoGenerateMinutes,
              let meeting = store.meeting(meetingID),
              !meeting.isRecording,
              meeting.minutesStatus == .none,
              meeting.allChunksTranscribed,
              !meeting.combinedTranscript.isEmpty else { return }
        generateMinutes(meetingID)
    }

    // MARK: Minuta

    func generateMinutes(_ meetingID: UUID) {
        guard let meeting = store.meeting(meetingID), meeting.minutesStatus != .generating else { return }
        guard !apiKey.isEmpty else {
            store.update(meetingID) { meeting in
                meeting.minutesStatus = .failed
                meeting.minutesError = "Configura tu API key de Groq en Ajustes."
            }
            return
        }
        let transcript = meeting.combinedTranscript
        guard !transcript.isEmpty else {
            store.update(meetingID) { meeting in
                meeting.minutesStatus = .failed
                meeting.minutesError = "No hay transcripción para generar la minuta."
            }
            return
        }

        let model = AppSettings.llmModel
        let client = GroqClient(apiKey: apiKey)
        let message = AppSettings.minutesPrompt + "\n\n" + transcript
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

        store.update(meetingID) { meeting in
            meeting.minutesStatus = .generating
            meeting.minutesError = nil
            meeting.lastLLMExchange = LLMExchange(date: Date(), model: model, request: prepared.rawText, response: nil)
        }

        Task {
            let activity = BackgroundActivity(name: "minutes")
            defer { activity.end() }
            var attempt = 0
            while true {
                attempt += 1
                do {
                    let result = try await client.send(prepared)
                    store.update(meetingID) { meeting in
                        meeting.minutes = result.content
                        meeting.minutesStatus = .done
                        meeting.minutesModel = model
                        meeting.minutesGeneratedAt = Date()
                        meeting.lastLLMExchange?.response = result.rawResponse
                    }
                    return
                } catch {
                    if GroqClient.isRetryable(error), attempt < 3 {
                        let delay = GroqClient.retryDelay(for: error, attempt: attempt)
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    let raw = (error as? GroqAPIError)?.rawResponse
                    store.update(meetingID) { meeting in
                        meeting.minutesStatus = .failed
                        meeting.minutesError = error.localizedDescription
                        if let raw {
                            meeting.lastLLMExchange?.response = raw
                        }
                    }
                    return
                }
            }
        }
    }
}
