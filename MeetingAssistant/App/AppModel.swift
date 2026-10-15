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

    private(set) var apiKey: String
    private(set) var activeMeetingID: UUID? = nil
    /// Última reunión grabada, para abrirla al cerrar la pantalla de grabación.
    private(set) var lastRecordedMeetingID: UUID? = nil
    var alertMessage: String? = nil
    private static let apiKeyAccount = "groq-api-key"

    init() {
        AppSettings.registerDefaults()
        let store = MeetingStore()
        self.store = store
        self.recorder = AudioChunkRecorder()
        self.processor = MeetingProcessor(store: store)
        self.player = AudioPlayer()
        self.apiKey = Keychain.read(Self.apiKeyAccount) ?? ""
        processor.updateAPIKey(apiKey)
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    var isRecording: Bool { recorder.state != .idle }

    var activeMeeting: Meeting? {
        activeMeetingID.flatMap { store.meeting($0) }
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != apiKey else { return }
        apiKey = trimmed
        if trimmed.isEmpty {
            Keychain.delete(Self.apiKeyAccount)
        } else {
            Keychain.save(trimmed, for: Self.apiKeyAccount)
        }
        processor.updateAPIKey(trimmed)
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
