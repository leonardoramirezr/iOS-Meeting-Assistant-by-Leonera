import SwiftUI

struct MeetingsListView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [UUID] = []
    @State private var showSettings = false
    @State private var isStarting = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !model.hasAPIKey {
                    Section {
                        NoticeRow(
                            systemImage: "key.fill",
                            title: "Falta la API key de Groq",
                            message: "Puedes grabar, pero para transcribir y generar la minuta necesitas configurarla.",
                            actionTitle: "Configurar",
                            action: { showSettings = true }
                        )
                    }
                }
                if let authError = model.processor.authError {
                    Section {
                        NoticeRow(
                            systemImage: "exclamationmark.triangle.fill",
                            title: "Transcripción detenida",
                            message: authError,
                            actionTitle: "Revisar API key",
                            action: { showSettings = true }
                        )
                    }
                }
                if let until = model.processor.pausedUntil, model.processor.isPaused {
                    Section {
                        PauseNotice(until: until, reason: model.processor.pauseReason) {
                            model.processor.resumeNow()
                        }
                        .padding(.vertical, 4)
                    }
                }
                if model.store.meetings.isEmpty {
                    ContentUnavailableView(
                        "Sin reuniones",
                        systemImage: "waveform",
                        description: Text("Pulsa «Grabar reunión» para empezar. La grabación se divide en bloques que se transcriben mientras sigues grabando.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(model.store.meetings) { meeting in
                            NavigationLink(value: meeting.id) {
                                MeetingRow(meeting: meeting)
                            }
                            .disabled(meeting.isRecording)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Reuniones")
            .navigationDestination(for: UUID.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Ajustes")
                }
            }
            .safeAreaInset(edge: .bottom) {
                recordButton
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: recordingPresented, onDismiss: openLastRecording) {
            RecordingView()
        }
        .alert("Aviso", isPresented: alertPresented) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var recordButton: some View {
        Button {
            guard !isStarting else { return }
            isStarting = true
            Task {
                await model.startRecording()
                isStarting = false
            }
        } label: {
            Label("Grabar reunión", systemImage: "record.circle")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .disabled(isStarting)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var recordingPresented: Binding<Bool> {
        Binding(
            get: { model.isRecording },
            set: { _ in }
        )
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { presented in
                if !presented { model.alertMessage = nil }
            }
        )
    }

    private func openLastRecording() {
        model.consumeAutoStopReason()
        if let id = model.lastRecordedMeetingID, model.store.meeting(id) != nil {
            path = [id]
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { model.store.meetings[$0].id }
        for id in ids {
            model.deleteMeeting(id)
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(meeting.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                Text("·")
                Text(Format.duration(meeting.duration))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            MeetingStatusLabel(meeting: meeting)
                .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

struct MeetingStatusLabel: View {
    let meeting: Meeting

    var body: some View {
        Label(text, systemImage: icon)
            .foregroundStyle(color)
    }

    private var text: String {
        if meeting.isRecording { return "Grabando…" }
        if meeting.isTranscribing {
            return "Transcribiendo \(meeting.transcribedCount) de \(meeting.chunks.count) bloques"
        }
        let plan = AppSettings.summaryPlan
        if plan.mode.usesSummaries, meeting.minutesStatus == .none || meeting.minutesStatus == .queued,
           !meeting.summariesComplete(for: plan) {
            let progress = meeting.summaryProgress(for: plan)
            return "Resumiendo \(progress.done) de \(progress.total)"
        }
        switch meeting.minutesStatus {
        case .queued: return "Minuta en cola"
        case .generating: return "Generando minuta…"
        case .failed: return "Error al generar la minuta"
        case .done: return "Minuta lista"
        case .none:
            if meeting.failedCount > 0 { return "\(meeting.failedCount) bloque(s) sin transcribir" }
            return "Transcripción lista"
        }
    }

    private var icon: String {
        if meeting.isRecording { return "record.circle" }
        if meeting.isTranscribing { return "waveform" }
        switch meeting.minutesStatus {
        case .queued: return "hourglass"
        case .generating: return "sparkles"
        case .failed: return "exclamationmark.triangle"
        case .done: return "doc.text"
        case .none: return meeting.failedCount > 0 ? "exclamationmark.triangle" : "text.alignleft"
        }
    }

    private var color: Color {
        if meeting.isRecording { return .red }
        if meeting.isTranscribing { return .blue }
        switch meeting.minutesStatus {
        case .queued: return .purple
        case .generating: return .purple
        case .failed: return .orange
        case .done: return .green
        case .none: return meeting.failedCount > 0 ? .orange : .secondary
        }
    }
}

struct NoticeRow: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }
}
