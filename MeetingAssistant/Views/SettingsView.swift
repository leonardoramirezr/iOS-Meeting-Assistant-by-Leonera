import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Key.transcriptionModel) private var transcriptionModel = AppSettings.defaultTranscriptionModel
    @AppStorage(AppSettings.Key.llmModel) private var llmModel = AppSettings.defaultLLMModel
    @AppStorage(AppSettings.Key.chunkLength) private var chunkLength = AppSettings.defaultChunkLength
    @AppStorage(AppSettings.Key.language) private var language = AppSettings.defaultLanguage
    @AppStorage(AppSettings.Key.autoGenerateMinutes) private var autoGenerateMinutes = true
    @AppStorage(AppSettings.Key.fetchedTranscriptionModels) private var fetchedTranscriptionModels = ""
    @AppStorage(AppSettings.Key.fetchedLLMModels) private var fetchedLLMModels = ""

    @State private var apiKeyDraft = ""
    @State private var revealKey = false
    @State private var fetchStatus: FetchStatus = .idle

    enum FetchStatus: Equatable {
        case idle
        case loading
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                groqSection
                modelsSection
                recordingSection
                minutesSection
                aboutSection
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        saveKey()
                        dismiss()
                    }
                }
            }
            .onAppear {
                apiKeyDraft = model.apiKey
            }
            .onDisappear {
                saveKey()
            }
        }
    }

    // MARK: Secciones

    private var groqSection: some View {
        Section {
            HStack {
                Group {
                    if revealKey {
                        TextField("gsk_…", text: $apiKeyDraft)
                    } else {
                        SecureField("gsk_…", text: $apiKeyDraft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .onSubmit(saveKey)
                Button {
                    revealKey.toggle()
                } label: {
                    Image(systemName: revealKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealKey ? "Ocultar API key" : "Mostrar API key")
            }
            Button {
                Task { await testAndLoadModels() }
            } label: {
                HStack {
                    Text("Guardar, probar y cargar modelos")
                    Spacer()
                    if fetchStatus == .loading {
                        ProgressView()
                    }
                }
            }
            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fetchStatus == .loading)
            switch fetchStatus {
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            case .idle, .loading:
                EmptyView()
            }
        } header: {
            Text("Groq")
        } footer: {
            Text("La API key se guarda en el llavero del iPhone. Puedes crear una en console.groq.com/keys.")
        }
    }

    private var modelsSection: some View {
        Section {
            ModelPickerRow(
                title: "Audio a texto",
                selection: $transcriptionModel,
                options: merged(AppSettings.suggestedTranscriptionModels, fetchedTranscriptionModels)
            )
            ModelPickerRow(
                title: "LLM para la minuta",
                selection: $llmModel,
                options: merged(AppSettings.suggestedLLMModels, fetchedLLMModels)
            )
        } header: {
            Text("Modelos")
        } footer: {
            Text("Usa «Guardar, probar y cargar modelos» para traer la lista actual de Groq, o elige «Otro…» para escribir el ID exacto de un modelo.")
        }
    }

    private var recordingSection: some View {
        Section {
            Picker("Tamaño de bloque", selection: $chunkLength) {
                ForEach(ChunkLength.allCases) { length in
                    Text(length.label).tag(length.rawValue)
                }
            }
            Picker("Idioma", selection: $language) {
                ForEach(TranscriptionLanguage.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } header: {
            Text("Grabación")
        } footer: {
            Text("Cada vez que se cumple el tamaño de bloque, el clip se cierra y se envía a Whisper mientras la grabación sigue en un clip nuevo. El cambio aplica a la siguiente grabación. Máximo 3 horas por reunión.")
        }
    }

    private var minutesSection: some View {
        Section {
            NavigationLink {
                PromptEditorView()
            } label: {
                Text("Prompt de la minuta")
            }
            Toggle("Generar al terminar la transcripción", isOn: $autoGenerateMinutes)
        } header: {
            Text("Minuta")
        } footer: {
            Text("Al prompt se le añade la transcripción completa; los bloques se separan con \(AppSettings.chunkBoundary).")
        }
    }

    private var aboutSection: some View {
        Section("Acerca de") {
            LabeledContent("Versión", value: Self.versionString)
            LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
        }
    }

    // MARK: Acciones

    private func saveKey() {
        model.saveAPIKey(apiKeyDraft)
    }

    private func testAndLoadModels() async {
        saveKey()
        fetchStatus = .loading
        do {
            let models = try await GroqClient(apiKey: model.apiKey).listModels()
            let ids = models.filter { $0.active ?? true }.map(\.id).sorted()
            let transcription = ids.filter { $0.localizedCaseInsensitiveContains("whisper") }
            let excluded = ["whisper", "tts", "guard", "orpheus", "playai"]
            let chat = ids.filter { id in
                !excluded.contains { id.localizedCaseInsensitiveContains($0) }
            }
            fetchedTranscriptionModels = transcription.joined(separator: "\n")
            fetchedLLMModels = chat.joined(separator: "\n")
            fetchStatus = .success("API key válida · \(transcription.count) modelos de audio y \(chat.count) de texto")
        } catch {
            fetchStatus = .failure(error.localizedDescription)
        }
    }

    private func merged(_ suggested: [String], _ fetched: String) -> [String] {
        let fetchedList = AppSettings.storedModelList(fetched)
        let base = fetchedList.isEmpty ? suggested : fetchedList
        var seen = Set<String>()
        return base.filter { seen.insert($0).inserted }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Selector de modelo con opción para escribir un ID arbitrario.
struct ModelPickerRow: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    @State private var showCustom = false
    @State private var customDraft = ""

    private static let customTag = "__custom_model__"

    var body: some View {
        Picker(title, selection: pickerSelection) {
            ForEach(allOptions, id: \.self) { option in
                Text(option).tag(option)
            }
            Text("Otro…").tag(Self.customTag)
        }
        .pickerStyle(.navigationLink)
        .alert("ID del modelo", isPresented: $showCustom) {
            TextField("p. ej. llama-3.3-70b-versatile", text: $customDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Usar") {
                let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    selection = trimmed
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Escribe el ID exacto tal como aparece en la consola de Groq.")
        }
    }

    private var allOptions: [String] {
        options.contains(selection) ? options : [selection] + options
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == Self.customTag {
                    customDraft = selection
                    showCustom = true
                } else {
                    selection = newValue
                }
            }
        )
    }
}

struct PromptEditorView: View {
    @AppStorage(AppSettings.Key.minutesPrompt) private var prompt = AppSettings.defaultMinutesPrompt
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $prompt)
                .font(.callout)
                .padding(.horizontal, 8)
            Text("Después de este texto se añade la transcripción de todos los bloques separados por \(AppSettings.chunkBoundary).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.bar)
        }
        .navigationTitle("Prompt de la minuta")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Restaurar") {
                    confirmReset = true
                }
                .disabled(prompt == AppSettings.defaultMinutesPrompt)
            }
        }
        .confirmationDialog("¿Restaurar el prompt predeterminado?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Restaurar", role: .destructive) {
                prompt = AppSettings.defaultMinutesPrompt
            }
        }
    }
}
