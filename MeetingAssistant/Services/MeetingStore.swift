import Foundation
import Observation

/// Bloque pendiente de transcribir.
struct ChunkJob {
    let meetingID: UUID
    let index: Int
    let fileURL: URL
}

/// Guarda cada reunión en `Documents/Meetings/<id>/` (audio + `meeting.json`).
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []

    let rootDirectory: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootDirectory = documents.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        load()
    }

    func directory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(meetingID: UUID, chunk: AudioChunk) -> URL {
        directory(for: meetingID).appendingPathComponent(chunk.fileName)
    }

    func meeting(_ id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    // MARK: Cambios

    func createMeeting(chunkDuration: TimeInterval) -> Meeting {
        let now = Date()
        let meeting = Meeting(
            id: UUID(),
            title: "Reunión \(now.formatted(date: .abbreviated, time: .shortened))",
            createdAt: now,
            isRecording: true,
            chunkDuration: chunkDuration
        )
        try? FileManager.default.createDirectory(at: directory(for: meeting.id), withIntermediateDirectories: true)
        meetings.insert(meeting, at: 0)
        save(meeting)
        return meeting
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        var meeting = meetings[index]
        change(&meeting)
        meetings[index] = meeting
        save(meeting)
    }

    func updateChunk(_ id: UUID, index chunkIndex: Int, _ change: (inout AudioChunk) -> Void) {
        update(id) { meeting in
            guard let position = meeting.chunks.firstIndex(where: { $0.index == chunkIndex }) else { return }
            change(&meeting.chunks[position])
        }
    }

    func addChunk(_ chunk: AudioChunk, to id: UUID) {
        update(id) { meeting in
            meeting.chunks.removeAll { $0.index == chunk.index }
            meeting.chunks.append(chunk)
            meeting.chunks.sort { $0.index < $1.index }
            meeting.duration = meeting.chunks.reduce(0) { $0 + $1.duration }
        }
    }

    func delete(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// Siguiente bloque en cola: primero la reunión que se está grabando, después las más antiguas.
    func nextPendingChunk() -> ChunkJob? {
        let ordered = meetings.sorted { lhs, rhs in
            if lhs.isRecording != rhs.isRecording { return lhs.isRecording }
            return lhs.createdAt < rhs.createdAt
        }
        for meeting in ordered {
            if let chunk = meeting.chunks.first(where: { $0.status == .pending }) {
                return ChunkJob(meetingID: meeting.id, index: chunk.index,
                                fileURL: audioURL(meetingID: meeting.id, chunk: chunk))
            }
        }
        return nil
    }

    // MARK: Persistencia

    private func save(_ meeting: Meeting) {
        let folder = directory(for: meeting.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try encoder.encode(meeting)
            try data.write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        } catch {
            print("No se pudo guardar la reunión \(meeting.id): \(error)")
        }
    }

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil
        )) ?? []
        var loaded: [Meeting] = []
        for folder in folders {
            let url = folder.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: url),
                  var meeting = try? decoder.decode(Meeting.self, from: data) else { continue }

            // Recupera el trabajo que quedó a medias si la app se cerró.
            var changed = false
            if meeting.isRecording {
                meeting.isRecording = false
                changed = true
            }
            for position in meeting.chunks.indices where meeting.chunks[position].status == .transcribing {
                meeting.chunks[position].status = .pending
                changed = true
            }
            if meeting.minutesStatus == .generating {
                meeting.minutesStatus = .failed
                meeting.minutesError = "La generación de la minuta se interrumpió al cerrarse la app."
                changed = true
            }
            if changed {
                save(meeting)
            }
            loaded.append(meeting)
        }
        meetings = loaded.sorted { $0.createdAt > $1.createdAt }
    }
}
