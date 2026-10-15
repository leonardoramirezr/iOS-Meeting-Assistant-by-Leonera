import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Key.transcriptionModel) private var transcriptionModel = AppSettings.defaultTranscriptionModel
    @AppStorage(AppSettings.Key.llmModel) private var llmModel = AppSettings.defaultLLMModel
    @AppStorage(AppSettings.Key.googleLLMModel) private var googleLLMModel = AppSettings.defaultGoogleLLMModel
    @AppStorage(AppSettings.Key.llmProvider) private var llmProvider = AppSettings.defaultLLMProvider
    @AppStorage(AppSettings.Key.fetchedGoogleModels) private var fetchedGoogleModels = ""
    @AppStorage(AppSettings.Key.chunkLength) private var chunkLength = AppSettings.defaultChunkLength
    @AppStorage(AppSettings.Key.language) private var language = AppSettings.defaultLanguage
    @AppStorage(AppSettings.Key.autoGenerateMinutes) private var autoGenerateMinutes = true
    @AppStorage(AppSettings.Key.fetchedTranscriptionModels) private var fetchedTranscriptionModels = ""
    @AppStorage(AppSettings.Key.fetchedLLMModels) private var fetchedLLMModels = ""
    @AppStorage(AppSettings.Key.processingMode) private var processingMode = AppSettings.defaultProcessingMode
    @AppStorage(AppSettings.Key.mapReduceGroupSize) private var groupSize = AppSettings.defaultMapReduceGroupSize
    @AppStorage(AppSettings.Key.quotaPause) private var quotaPause = AppSettings.defaultQuotaPause
    @AppStorage(AppSettings.Key.preventiveRateLimitPause) private var preventivePause = true
    @AppStorage(AppSettings.Key.rateLimitTokenThreshold) private var tokenThreshold = AppSettings.defaultRateLimitTokenThreshold


    var body: some View {
        NavigationStack {
            Form {
                APIKeySection(provider: .groq, load: { try await loadModels(for: .groq) })
                APIKeySection(provider: .google, load: { try await loadModels(for: .google) })
                modelsSection
                recordingSection
                processingSection
                rateLimitSection
                minutesSection
                aboutSection
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        dismiss()
                    }
                }
            }
            .onChange(of: llmProvider) { _, _ in
                model.processor.kick()
            }
            .onChange(of: processingMode) { _, _ in
                model.processor.kick()
            }
            .onChange(of: groupSize) { _, _ in
                model.processor.kick()
            }
        }
    }

    // MARK: Secciones

    private var modelsSection: some View {
        Section {
            ModelPickerRow(
                title: "Audio a texto",
                selection: $transcriptionModel,
                options: merged(AppSettings.suggestedTranscriptionModels, fetchedTranscriptionModels)
            )
            Picker("Proveedor del LLM", selection: $llmProvider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.label).tag(provider.rawValue)
                }
            }
            .pickerStyle(.segmented)
            if llmProvider == LLMProvider.google.rawValue {
                ModelPickerRow(
                    title: "LLM para la minuta",
                    selection: $googleLLMModel,
                    options: merged(AppSettings.suggestedGoogleModels, fetchedGoogleModels)
                )
            } else {
                ModelPickerRow(
                    title: "LLM para la minuta",
                    selection: $llmModel,
                    options: merged(AppSettings.suggestedLLMModels, fetchedLLMModels)
                )
            }
        } header: {
            Text("Modelos")
        } footer: {
            Text("La transcripción (audio a texto) siempre usa Groq: la API compatible con OpenAI de Google no ofrece transcripción. Para el LLM (resúmenes y minuta) elige primero Groq o Google y después el modelo. Usa «Guardar, probar y cargar modelos» en la sección de cada proveedor para traer su lista actual, o elige «Otro…» para escribir el ID exacto.")
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

    private var selectedMode: ProcessingMode {
        ProcessingMode(rawValue: processingMode) ?? .fullTranscript
    }

    private var processingFooter: String {
        var text = selectedMode.detail
        if selectedMode == .mapReduce {
            let length = ChunkLength(rawValue: chunkLength)?.label ?? Format.duration(chunkLength)
            text += " Cada grupo reúne \(groupSize) bloques de \(length) (≈ \(Format.duration(Double(groupSize) * chunkLength)))."
        }
        text += "\n\nSi Groq responde con un límite de cuota (429), el procesamiento se pausa ese tiempo y se reanuda solo; si iOS suspende la app, se reanuda al volver a abrirla."
        text += " Al cambiar la forma de procesar se borran los resúmenes de las reuniones sin minuta y se empieza de nuevo."
        return text
    }

    private var processingSection: some View {
        Section {
            Picker("Forma de procesar", selection: $processingMode) {
                ForEach(ProcessingMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if selectedMode == .mapReduce {
                Stepper(value: $groupSize, in: AppSettings.mapReduceGroupSizeRange) {
                    LabeledContent("Bloques por grupo", value: "\(groupSize)")
                }
            }
            Picker("Pausa por límite de cuota", selection: $quotaPause) {
                ForEach(QuotaPause.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } header: {
            Text("Forma de procesar la minuta")
        } footer: {
            Text(processingFooter)
        }
    }

    private var rateLimitSection: some View {
        Section {
            Toggle("Pausar antes de agotar los tokens", isOn: $preventivePause)
            if preventivePause {
                LabeledContent("Pausar con tokens restantes ≤") {
                    TextField("1000", value: $tokenThreshold, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                }
            }
        } header: {
            Text("Límite de tokens")
        } footer: {
            Text("Si una respuesta de Groq trae x-ratelimit-remaining-tokens menor o igual a \(tokenThreshold), las peticiones se pausan hasta que el límite se restablezca (x-ratelimit-reset-tokens) o, si Groq no lo indica, el tiempo de «Pausa por límite de cuota». Así se evita llegar al límite y que Groq bloquee la cuenta.")
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

    /// Guarda la key ya hecha por `APIKeySection`, pide la lista de modelos y la guarda.
    private func loadModels(for provider: LLMProvider) async throws -> String {
        let models = try await GroqClient(apiKey: model.apiKey(for: provider), provider: provider).listModels()
        let ids = models.filter { $0.active ?? true }.map(\.id).sorted()
        switch provider {
        case .groq:
            let transcription = ids.filter { $0.localizedCaseInsensitiveContains("whisper") }
            let excluded = ["whisper", "tts", "guard", "orpheus", "playai"]
            let chat = ids.filter { id in
                !excluded.contains { id.localizedCaseInsensitiveContains($0) }
            }
            fetchedTranscriptionModels = transcription.joined(separator: "\n")
            fetchedLLMModels = chat.joined(separator: "\n")
            return "API key válida · \(transcription.count) modelos de audio y \(chat.count) de texto"
        case .google:
            let excluded = ["embedding", "imagen", "veo", "aqa", "tts", "image-generation", "native-audio", "live"]
            let chat = ids.filter { id in
                !excluded.contains { id.localizedCaseInsensitiveContains($0) }
            }
            fetchedGoogleModels = chat.joined(separator: "\n")
            return "API key válida · \(chat.count) modelos de texto"
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

/// Sección con la API key de un proveedor (cada una se guarda por separado en el llavero).
struct APIKeySection: View {
    @Environment(AppModel.self) private var model
    let provider: LLMProvider
    let load: () async throws -> String

    @State private var draft = ""
    @State private var reveal = false
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case loading
        case success(String)
        case failure(String)
    }

    var body: some View {
        Section {
            HStack {
                Group {
                    if reveal {
                        TextField(provider.keyPlaceholder, text: $draft)
                    } else {
                        SecureField(provider.keyPlaceholder, text: $draft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .onSubmit(save)
                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(reveal ? "Ocultar API key" : "Mostrar API key")
            }
            Button {
                Task { await testAndLoad() }
            } label: {
                HStack {
                    Text("Guardar, probar y cargar modelos")
                    Spacer()
                    if status == .loading {
                        ProgressView()
                    }
                }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .loading)
            switch status {
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
            Text(provider.label)
        } footer: {
            Text("La API key se guarda en el llavero del iPhone. Puedes crear una en \(provider.consoleHint).")
        }
        .onAppear {
            draft = model.apiKey(for: provider)
        }
        .onDisappear(perform: save)
    }

    private func save() {
        model.saveAPIKey(draft, for: provider)
    }

    private func testAndLoad() async {
        save()
        status = .loading
        do {
            status = .success(try await load())
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
