import SwiftUI

struct RecordingView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    RecordingClock()
                    ChunkProgressCard()
                    if let message = model.recorder.statusMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.hasAPIKey {
                        Label("Sin API key de Groq: los bloques se guardan y se transcribirán cuando la configures.",
                              systemImage: "key.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let until = model.processor.pausedUntil, model.processor.isPaused {
                        PauseNotice(until: until, reason: model.processor.pauseReason) {
                            model.processor.resumeNow()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    RecordedChunksList()
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                controls
            }
            .navigationTitle(model.activeMeeting?.title ?? "Grabación")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("¿Terminar la grabación?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Terminar y transcribir", role: .destructive) {
                    model.stopRecording()
                }
                Button("Seguir grabando", role: .cancel) {}
            } message: {
                Text("El último bloque se enviará a transcribir y después se generará la minuta.")
            }
        }
        .interactiveDismissDisabled()
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if model.recorder.state == .paused {
                Button {
                    model.recorder.resume()
                } label: {
                    Label("Reanudar", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    model.recorder.pause()
                } label: {
                    Label("Pausar", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                confirmStop = true
            } label: {
                Label("Terminar", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .controlSize(.large)
        .font(.headline)
        .padding()
        .background(.bar)
    }
}

private struct RecordingClock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(recorder.state == .recording ? Color.red : Color.orange)
                    .frame(width: 10, height: 10)
                Text(recorder.state == .recording ? "Grabando" : "En pausa")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(Format.clock(recorder.recordedDuration))
                .font(.system(size: 60, weight: .light, design: .rounded))
                .monospacedDigit()
            LevelMeter(level: recorder.level)
                .frame(maxWidth: 260)
            Text("Máximo \(Format.clock(recorder.maxDuration)) · quedan \(Format.clock(max(0, recorder.maxDuration - recorder.recordedDuration)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }
}

private struct ChunkProgressCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        let progress = recorder.chunkDuration > 0 ? min(recorder.chunkElapsed / recorder.chunkDuration, 1) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bloque \(recorder.chunkIndex + 1)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("corte en \(Format.clock(max(0, recorder.chunkDuration - recorder.chunkElapsed)))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(.red)
            Text("Cada \(Format.duration(recorder.chunkDuration)) se cierra el clip actual y se envía a Whisper mientras la grabación continúa en un clip nuevo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}

private struct RecordedChunksList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let chunks = model.activeMeeting?.chunks ?? []
        let summarized = model.activeMeeting?.summarizedIndices ?? []
        if !chunks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bloques guardados")
                    .font(.headline)
                ForEach(Array(chunks.reversed())) { chunk in
                    HStack(alignment: .top, spacing: 10) {
                        ChunkStatusIcon(status: chunk.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bloque \(chunk.index + 1) · \(Format.clock(chunk.duration))")
                                .font(.subheadline.weight(.medium))
                            Text(preview(for: chunk))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if summarized.contains(chunk.index) {
                            CloudProcessedBadge()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func preview(for chunk: AudioChunk) -> String {
        switch chunk.status {
        case .pending: return chunk.error ?? "En cola para transcribir"
        case .transcribing: return "Transcribiendo…"
        case .failed: return chunk.error ?? "Error al transcribir"
        case .deleted: return "Transcripción eliminada"
        case .done:
            let text = chunk.transcript ?? ""
            return text.isEmpty ? "(sin voz detectada)" : text
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(level > 0.9 ? Color.orange : Color.red)
                    .frame(width: max(8, proxy.size.width * CGFloat(level)))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.2), value: level)
        .accessibilityHidden(true)
    }
}

struct ChunkStatusIcon: View {
    let status: ChunkStatus

    var body: some View {
        Group {
            switch status {
            case .pending:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .deleted:
                Image(systemName: "trash.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}

/// Indica que el bloque ya se resumió en la nube.
struct CloudProcessedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.icloud.fill")
            .foregroundStyle(.blue)
            .accessibilityLabel("Procesado en la nube")
    }
}
