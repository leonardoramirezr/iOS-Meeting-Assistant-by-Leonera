import SwiftUI
import UIKit

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID

    enum DetailTab: String, CaseIterable, Identifiable {
        case minutes = "Minuta"
        case transcript = "Transcripción"
        case summaries = "Resúmenes"
        var id: Self { self }
    }

    @State private var tab: DetailTab = .minutes
    @State private var showRawRequest = false
    @State private var isRenaming = false
    @State private var titleDraft = ""
    @State private var confirmDelete = false

    var body: some View {
        if let meeting = model.store.meeting(meetingID) {
            content(meeting)
        } else {
            ContentUnavailableView("Reunión no disponible", systemImage: "questionmark.folder")
        }
    }

    private func tabs(for meeting: Meeting) -> [DetailTab] {
        meeting.summaries.isEmpty ? [.minutes, .transcript] : DetailTab.allCases
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MeetingHeader(meeting: meeting)
                Picker("Vista", selection: $tab) {
                    ForEach(tabs(for: meeting)) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .minutes:
                    MinutesSection(meeting: meeting, showRawRequest: $showRawRequest)
                case .transcript:
                    TranscriptSection(meeting: meeting)
                case .summaries:
                    if meeting.summaries.isEmpty {
                        MinutesSection(meeting: meeting, showRawRequest: $showRawRequest)
                    } else {
                        SummariesSection(meeting: meeting)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                actionsMenu(meeting)
            }
        }
        .sheet(isPresented: $showRawRequest) {
            if let exchange = meeting.lastLLMExchange {
                RawExchangeView(exchange: exchange)
            }
        }
        .alert("Renombrar reunión", isPresented: $isRenaming) {
            TextField("Título", text: $titleDraft)
            Button("Guardar") {
                model.rename(meeting.id, to: titleDraft)
            }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog("¿Eliminar la reunión?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Eliminar audio, transcripción y minuta", role: .destructive) {
                model.deleteMeeting(meeting.id)
                dismiss()
            }
        }
    }

    private func actionsMenu(_ meeting: Meeting) -> some View {
        Menu {
            Button {
                titleDraft = meeting.title
                isRenaming = true
            } label: {
                Label("Renombrar", systemImage: "pencil")
            }
            if let minutes = meeting.minutes {
                ShareLink(item: minutes) {
                    Label("Compartir minuta", systemImage: "doc.text")
                }
            }
            if !meeting.combinedTranscript.isEmpty {
                ShareLink(item: meeting.combinedTranscript) {
                    Label("Compartir transcripción", systemImage: "text.alignleft")
                }
            }
            if meeting.failedCount > 0 {
                Button {
                    model.processor.retryFailedChunks(meeting.id)
                } label: {
                    Label("Reintentar bloques fallidos", systemImage: "arrow.clockwise")
                }
            }
            if meeting.lastLLMExchange != nil {
                Button {
                    showRawRequest = true
                } label: {
                    Label("Ver request raw al LLM", systemImage: "curlybraces")
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Acciones")
    }
}

private struct MeetingHeader: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.title2.weight(.semibold))
            Text(meeting.createdAt, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(Format.duration(meeting.duration), systemImage: "clock")
                Label("\(meeting.chunks.count) bloques de \(Format.duration(meeting.chunkDuration))",
                      systemImage: "square.stack.3d.up")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            MeetingStatusLabel(meeting: meeting)
                .font(.footnote)
        }
    }
}

// MARK: - Minuta

private struct MinutesSection: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @Binding var showRawRequest: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProcessingStatusCard(meeting: meeting)
            if meeting.minutesStatus == .generating {
                StatusCard {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Generando minuta…")
                                .font(.subheadline.weight(.semibold))
                            Text(meeting.lastLLMExchange?.model ?? AppSettings.llmModel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if meeting.minutesStatus == .failed {
                StatusCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No se pudo generar la minuta", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(meeting.minutesError ?? "Error desconocido.")
                            .font(.footnote)
                            .textSelection(.enabled)
                        Button("Reintentar") {
                            model.processor.generateMinutes(meeting.id)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!meeting.canGenerateMinutes)
                    }
                }
            }

            if let minutes = meeting.minutes, meeting.minutesStatus != .generating {
                MarkdownView(markdown: minutes)
                minutesFooter(minutes)
            } else if meeting.minutesStatus == .none {
                pendingState
            } else if meeting.minutesStatus == .queued {
                StatusCard {
                    Label("La minuta está en cola: se generará en cuanto terminen los resúmenes o la pausa por cuota.",
                          systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if meeting.lastLLMExchange != nil {
                Button {
                    showRawRequest = true
                } label: {
                    Label("request raw", systemImage: "curlybraces")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Ver el request raw enviado al LLM")
            }
        }
    }

    private func minutesFooter(_ minutes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let modelName = meeting.minutesModel, let date = meeting.minutesGeneratedAt {
                Text("Generada con \(modelName) · \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = minutes
                    copied = true
                } label: {
                    Label(copied ? "Copiada" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: minutes) {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                }
                Spacer()
                Button {
                    model.processor.generateMinutes(meeting.id)
                } label: {
                    Label("Regenerar", systemImage: "arrow.clockwise")
                }
                .disabled(!meeting.canGenerateMinutes)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var pendingState: some View {
        if meeting.isRecording || meeting.isTranscribing {
            StatusCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcribiendo…")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: Double(meeting.transcribedCount), total: Double(max(meeting.chunks.count, 1)))
                    Text("\(meeting.transcribedCount) de \(meeting.chunks.count) bloques. La minuta se generará al terminar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.hasAPIKey {
                        Text("Configura la API key de \(AppSettings.transcriptionProvider.keyLabel) en Ajustes para continuar.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } else if meeting.canGenerateMinutes {
            StatusCard {
                VStack(alignment: .leading, spacing: 10) {
                    if meeting.failedCount > 0 {
                        Label("\(meeting.failedCount) bloque(s) no se pudieron transcribir. Reinténtalos desde la pestaña Transcripción o genera la minuta sin ellos.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        model.processor.generateMinutes(meeting.id)
                    } label: {
                        Label("Generar minuta", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text("Modelo: \(AppSettings.llmModel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            StatusCard {
                Text("No hay transcripción disponible para generar la minuta.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Estado del procesamiento

/// Pausa por cuota, progreso de los resúmenes y errores de resumen.
struct ProcessingStatusCard: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        let plan = AppSettings.summaryPlan
        let showsSummaries = plan.mode.usesSummaries
            && meeting.minutesStatus != .done && meeting.minutesStatus != .generating
        if model.processor.isPaused || showsSummaries {
            StatusCard {
                VStack(alignment: .leading, spacing: 10) {
                    if let until = model.processor.pausedUntil, model.processor.isPaused {
                        PauseNotice(until: until, reason: model.processor.pauseReason) {
                            model.processor.resumeNow()
                        }
                    }
                    if showsSummaries {
                        summaryProgress(plan)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryProgress(_ plan: SummaryPlan) -> some View {
        let progress = meeting.summaryProgress(for: plan)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(plan.mode.label, systemImage: "icloud.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.processor.isSummarizing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text(plan.mode == .iterative
                 ? "\(progress.done) de \(progress.total) bloques integrados al resumen acumulado."
                 : "\(progress.done) de \(progress.total) segmentos resumidos.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = meeting.summaryError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Button("Reintentar resúmenes") {
                    model.processor.retrySummaries(meeting.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

struct PauseNotice: View {
    let until: Date
    var reason: String? = nil
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(reason ?? "En pausa por límite de cuota de Groq", systemImage: "pause.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Se reanuda sola a las \(until.formatted(date: .omitted, time: .standard)) (\(Text(until, style: .relative))).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reanudar ahora", action: resume)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

// MARK: - Resúmenes

private struct SummariesSection: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if meeting.summaryPlan?.mode == .iterative, let last = meeting.summaries.last {
                Text("Resumen acumulado tras \(meeting.summaries.count) bloque(s)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                StatusCard {
                    MarkdownView(markdown: last.text)
                }
            } else {
                Text("\(meeting.summaries.count) resumen(es) · \(meeting.summaryPlan?.mode.label ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(Array(meeting.summaries.enumerated()), id: \.offset) { _, summary in
                    StatusCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(title(summary), systemImage: "checkmark.icloud.fill")
                                .font(.subheadline.weight(.semibold))
                            MarkdownView(markdown: summary.text)
                        }
                    }
                }
            }
        }
    }

    private func title(_ summary: SegmentSummary) -> String {
        let first = (summary.chunkIndices.first ?? 0) + 1
        let last = (summary.chunkIndices.last ?? 0) + 1
        return first == last ? "Bloque \(first)" : "Bloques \(first)–\(last)"
    }
}

// MARK: - Transcripción

private struct TranscriptSection: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var copied = false
    @State private var confirmRegenerate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(meeting.transcribedCount) de \(meeting.chunks.count) bloques transcritos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !meeting.combinedTranscript.isEmpty {
                    Button {
                        UIPasteboard.general.string = meeting.combinedTranscript
                        copied = true
                    } label: {
                        Label(copied ? "Copiada" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let message = model.player.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(meeting.chunks) { chunk in
                ChunkCard(meeting: meeting, chunk: chunk)
            }
            if !meeting.chunks.isEmpty {
                transcriptFooter
            }
        }
        .confirmationDialog("¿Regenerar la transcripción?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerar con \(currentModelLabel)") {
                model.processor.regenerateTranscript(meeting.id)
            }
        } message: {
            Text("Se volverán a transcribir los \(meeting.chunks.count) bloques (incluidos los borrados) y se reemplazará el texto actual. La minuta no cambia hasta que la regeneres.")
        }
    }

    /// Modelo de audio a texto seleccionado ahora mismo en Ajustes.
    private var currentModelLabel: String {
        let provider = AppSettings.transcriptionProvider
        return "\(AppSettings.transcriptionModel(for: provider)) (\(provider.label))"
    }

    /// Modelos con los que se generó la transcripción y fecha del último bloque transcrito.
    private var generatedNote: String? {
        let done = meeting.chunks.filter { $0.status == .done }
        var labels: [String] = []
        for label in done.compactMap(\.modelLabel) where !labels.contains(label) {
            labels.append(label)
        }
        guard !labels.isEmpty else { return nil }
        var note = "Generada con \(labels.joined(separator: ", "))"
        if let date = done.compactMap(\.transcribedAt).max() {
            note += " · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return note
    }

    private var transcriptFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let generatedNote {
                Text(generatedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Modelo seleccionado: \(currentModelLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    confirmRegenerate = true
                } label: {
                    Label("Regenerar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!meeting.canRegenerateTranscript || !model.hasAPIKey)
            }
        }
        .padding(.top, 8)
    }
}

private struct ChunkCard: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let chunk: AudioChunk
    @State private var confirmDelete = false

    /// Solo se borran bloques que ya terminaron de transcribirse (o fallaron).
    private var canDelete: Bool {
        chunk.status == .done || chunk.status == .failed
    }

    var body: some View {
        let url = model.store.audioURL(meetingID: meeting.id, chunk: chunk)
        let start = meeting.startOffset(of: chunk)
        let isPlaying = model.player.playingURL == url
        StatusCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ChunkStatusIcon(status: chunk.status)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text("Bloque \(chunk.index + 1)")
                                .font(.subheadline.weight(.semibold))
                            if meeting.isSummarized(chunk) {
                                CloudProcessedBadge()
                                    .font(.caption)
                            }
                        }
                        Text("\(Format.clock(start)) – \(Format.clock(start + chunk.duration))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.player.toggle(url)
                    } label: {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRecording)
                    .accessibilityLabel(isPlaying ? "Detener audio" : "Reproducir audio")
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Compartir audio")
                    if canDelete {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .tint(.red)
                        .accessibilityLabel("Borrar transcripción del bloque")
                    }
                }
                chunkBody
            }
        }
        .confirmationDialog("¿Borrar la transcripción del bloque \(chunk.index + 1)?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Borrar transcripción", role: .destructive) {
                model.processor.deleteChunkTranscript(meeting.id, index: chunk.index)
            }
        } message: {
            Text("El audio se conserva. El bloque se volverá a generar cuando regeneres la transcripción.")
        }
    }

    @ViewBuilder
    private var chunkBody: some View {
        switch chunk.status {
        case .done:
            let text = chunk.transcript ?? ""
            Text(text.isEmpty ? "(sin voz detectada)" : text)
                .font(.callout)
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .textSelection(.enabled)
            if let label = chunk.modelLabel {
                Text("Generado con \(label)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case .pending:
            Text(chunk.error ?? "En cola para transcribir.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .transcribing:
            Text("Transcribiendo…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text(chunk.error ?? "Error al transcribir.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Button("Reintentar") {
                    model.processor.retryChunk(meeting.id, index: chunk.index)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .deleted:
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcripción eliminada. Se volverá a generar al regenerar la transcripción.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Transcribir de nuevo") {
                    model.processor.retryChunk(meeting.id, index: chunk.index)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.hasAPIKey)
            }
        }
    }
}

struct StatusCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}
