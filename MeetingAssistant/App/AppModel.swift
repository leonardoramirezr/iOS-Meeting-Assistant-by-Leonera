import Foundation
import Observation

/// Estado global de la app: une la grabación, el almacenamiento y el procesamiento.
@MainActor
@Observable
final class AppModel {
    let store: MeetingStore
    let recorder: AudioChunkRecorder
    let processor: MeetingProcessor
    let player: AudioPlayer

    /// API keys guardadas en el llavero, por `LLMProvider.credentialID`.
    private(set) var apiKeys: [String: String] = [:]
    /// Proveedores compatibles con OpenAI añadidos por el usuario.
    private(set) var customProviders: [LLMProvider] = []
    private(set) var activeMeetingID: UUID? = nil
    /// Última reunión grabada, para abrirla al cerrar la pantalla de grabación.
    private(set) var lastRecordedMeetingID: UUID? = nil
    var alertMessage: String? = nil

    init() {
        AppSettings.registerDefaults()
        let store = MeetingStore()
        self.store = store
        self.recorder = AudioChunkRecorder()
        self.processor = MeetingProcessor(store: store)
        self.player = AudioPlayer()
        customProviders = AppSettings.customProviders
        for provider in AppSettings.allProviders {
            let key = Keychain.read(provider.keychainAccount) ?? ""
            apiKeys[provider.credentialID] = key
            processor.updateAPIKey(key, for: provider)
        }
    }

    /// Hay key para el proveedor de transcripción (o no la necesita).
    var hasAPIKey: Bool { hasKey(for: AppSettings.transcriptionProvider) }

    func hasKey(for provider: LLMProvider) -> Bool {
        !provider.requiresAPIKey || !apiKey(for: provider).isEmpty
    }

    var isRecording: Bool { recorder.state != .idle }

    var activeMeeting: Meeting? {
        activeMeetingID.flatMap { store.meeting($0) }
    }

    /// API key de Groq.
    var apiKey: String { apiKey(for: .groq) }

    var allProviders: [LLMProvider] { LLMProvider.builtIn + customProviders }

    func apiKey(for provider: LLMProvider) -> String {
        apiKeys[provider.credentialID, default: ""]
    }

    func saveAPIKey(_ key: String, for provider: LLMProvider = .groq) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != apiKey(for: provider) else { return }
        apiKeys[provider.credentialID] = trimmed
        if trimmed.isEmpty {
            Keychain.delete(provider.keychainAccount)
        } else {
            Keychain.save(trimmed, for: provider.keychainAccount)
        }
        processor.updateAPIKey(trimmed, for: provider)
    }

    // MARK: Proveedores personalizados

    /// Crea o actualiza un proveedor personalizado.
    func saveCustomProvider(_ provider: LLMProvider) {
        guard !provider.isBuiltIn else { return }
        if let index = customProviders.firstIndex(where: { $0.id == provider.id }) {
            customProviders[index] = provider
        } else {
            customProviders.append(provider)
        }
        AppSettings.customProviders = customProviders
        processor.kick()
    }

    /// Elimina el proveedor, su API key y, si estaba seleccionado, vuelve a Groq.
    func deleteCustomProvider(_ provider: LLMProvider) {
        guard !provider.isBuiltIn else { return }
        customProviders.removeAll { $0.id == provider.id }
        AppSettings.customProviders = customProviders
        Keychain.delete(provider.keychainAccount)
        apiKeys[provider.id] = nil
        processor.updateAPIKey("", for: provider)
        let defaults = UserDefaults.standard
        if defaults.string(forKey: AppSettings.Key.llmProvider) == provider.id {
            defaults.set(LLMProvider.groq.id, forKey: AppSettings.Key.llmProvider)
        }
        if defaults.string(forKey: AppSettings.Key.transcriptionProvider) == provider.id {
            defaults.set(LLMProvider.groq.id, forKey: AppSettings.Key.transcriptionProvider)
        }
        for key in [AppSettings.Key.llmModel(for: provider), AppSettings.Key.transcriptionModel(for: provider),
                    AppSettings.Key.fetchedLLMModels(for: provider),
                    AppSettings.Key.fetchedTranscriptionModels(for: provider)] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Grabación

    func startRecording() async {
        guard !isRecording else { return }
        player.stop()
        guard await AudioChunkRecorder.requestPermission() else {
            alertMessage = "Para grabar, permite el acceso al micrófono en Ajustes › Privacidad y seguridad › Micrófono."
            return
        }
        let chunkDuration = AppSettings.chunkLength
        let meeting = store.createMeeting(chunkDuration: chunkDuration)
        let meetingID = meeting.id
        do {
            try recorder.start(
                directory: store.directory(for: meetingID),
                chunkDuration: chunkDuration,
                onChunk: { [weak self] chunk in
                    self?.chunkRecorded(chunk, meetingID: meetingID)
                },
                onStop: { [weak self] in
                    self?.recordingStopped(meetingID: meetingID)
                }
            )
            activeMeetingID = meetingID
            lastRecordedMeetingID = meetingID
        } catch {
            store.delete(meetingID)
            alertMessage = "No se pudo iniciar la grabación: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recorder.stop()
    }

    /// Se llama al cerrar la pantalla de grabación.
    func consumeAutoStopReason() {
        if let reason = recorder.autoStopReason {
            alertMessage = reason
        }
    }

    private func chunkRecorded(_ chunk: RecordedChunk, meetingID: UUID) {
        store.addChunk(
            AudioChunk(index: chunk.index, fileName: chunk.url.lastPathComponent, duration: chunk.duration),
            to: meetingID
        )
        processor.kick()
    }

    private func recordingStopped(meetingID: UUID) {
        if activeMeetingID == meetingID {
            activeMeetingID = nil
        }
        store.update(meetingID) { meeting in
            meeting.isRecording = false
        }
        guard let meeting = store.meeting(meetingID), !meeting.chunks.isEmpty else {
            // No se llegó a grabar ni un segundo.
            store.delete(meetingID)
            return
        }
        // Un último intento con los bloques que fallaron durante la grabación.
        processor.retryFailedChunks(meetingID)
        processor.checkCompletion(meetingID)
    }

    // MARK: Reuniones

    func deleteMeeting(_ id: UUID) {
        guard id != activeMeetingID else { return }
        if let meeting = store.meeting(id), let url = player.playingURL,
           url.deletingLastPathComponent().standardizedFileURL == store.directory(for: meeting.id).standardizedFileURL {
            player.stop()
        }
        store.delete(id)
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.update(id) { meeting in
            meeting.title = trimmed
        }
    }
}
