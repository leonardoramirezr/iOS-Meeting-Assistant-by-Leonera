import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Key.llmProvider) private var llmProviderID = AppSettings.defaultLLMProvider
    @AppStorage(AppSettings.Key.transcriptionProvider) private var transcriptionProviderID = LLMProvider.groq.id
    @AppStorage(AppSettings.Key.chunkLength) private var chunkLength = AppSettings.defaultChunkLength
    @AppStorage(AppSettings.Key.language) private var language = AppSettings.defaultLanguage
    @AppStorage(AppSettings.Key.autoGenerateMinutes) private var autoGenerateMinutes = true
    @AppStorage(AppSettings.Key.processingMode) private var processingMode = AppSettings.defaultProcessingMode
    @AppStorage(AppSettings.Key.mapReduceGroupSize) private var groupSize = AppSettings.defaultMapReduceGroupSize
    @AppStorage(AppSettings.Key.quotaPause) private var quotaPause = AppSettings.defaultQuotaPause
    @AppStorage(AppSettings.Key.preventiveRateLimitPause) private var preventivePause = true
    @AppStorage(AppSettings.Key.rateLimitTokenThreshold) private var tokenThreshold = AppSettings.defaultRateLimitTokenThreshold

    /// Las claves de modelo dependen del proveedor (no caben en un `@AppStorage` fijo):
    /// se leen de `UserDefaults` y este contador fuerza el redibujado al cambiarlas.
    @State private var revision = 0

    var body: some View {
        NavigationStack {
            Form {
                ForEach(LLMProvider.builtIn) { provider in
                    APIKeySection(provider: provider, load: { try await loadModels(for: provider) })
                }
                customProvidersSection
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
            .onChange(of: llmProviderID) { _, _ in
                model.processor.kick()
            }
            .onChange(of: transcriptionProviderID) { _, _ in
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

    private var transcriptionProviders: [LLMProvider] {
        model.allProviders.filter(\.supportsTranscription)
    }

    private var transcriptionProvider: LLMProvider {
        transcriptionProviders.first { $0.id == transcriptionProviderID } ?? .groq
    }

    private var llmProvider: LLMProvider {
        model.allProviders.first { $0.id == llmProviderID } ?? .groq
    }

    private func storedString(_ key: String, default fallback: String) -> Binding<String> {
        Binding(
            get: {
                _ = revision
                return UserDefaults.standard.string(forKey: key) ?? fallback
            },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: key)
                revision += 1
                model.processor.kick()
            }
        )
    }

    private func fetchedList(_ key: String) -> String {
        _ = revision
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    private var modelsSection: some View {
        let transcription = transcriptionProvider
        let llm = llmProvider
        return Section {
            Picker("Proveedor de audio a texto", selection: $transcriptionProviderID) {
                ForEach(transcriptionProviders) { provider in
                    Text(provider.label).tag(provider.id)
                }
            }
            ModelPickerRow(
                title: "Modelo de audio a texto",
                selection: storedString(AppSettings.Key.transcriptionModel(for: transcription),
                                        default: AppSettings.transcriptionModel(for: transcription)),
                options: merged(transcription.id == LLMProvider.groq.id ? AppSettings.suggestedTranscriptionModels : [],
                                fetchedList(AppSettings.Key.fetchedTranscriptionModels(for: transcription)))
            )
            .id("transcription-\(transcription.id)")
            Picker("Proveedor del LLM", selection: $llmProviderID) {
                ForEach(model.allProviders) { provider in
                    Text(provider.label).tag(provider.id)
                }
            }
            ModelPickerRow(
                title: "Modelo del LLM (minuta)",
                selection: storedString(AppSettings.Key.llmModel(for: llm),
                                        default: AppSettings.llmModel(for: llm)),
                options: merged(suggestedLLMModels(for: llm),
                                fetchedList(AppSettings.Key.fetchedLLMModels(for: llm)))
            )
            .id("llm-\(llm.id)")
        } header: {
            Text("Modelos")
        } footer: {
            Text("Elige primero el proveedor y después el modelo. La transcripción solo puede usar proveedores con /audio/transcriptions (Groq, o uno personalizado marcado así): la API compatible con OpenAI de Google no la ofrece. Usa «Guardar, probar y cargar modelos» de cada proveedor para traer su lista actual, o elige «Otro…» para escribir el ID exacto.")
        }
    }

    private func suggestedLLMModels(for provider: LLMProvider) -> [String] {
        switch provider.id {
        case LLMProvider.groq.id: return AppSettings.suggestedLLMModels
        case LLMProvider.google.id: return AppSettings.suggestedGoogleModels
        default: return []
        }
    }

    private var customProvidersSection: some View {
        Section {
            ForEach(model.customProviders) { provider in
                NavigationLink {
                    CustomProviderEditor(provider: provider, load: { try await loadModels(for: $0) })
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                        Text(provider.baseURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            NavigationLink {
                CustomProviderEditor(provider: nil, load: { try await loadModels(for: $0) })
            } label: {
                Label("Añadir proveedor compatible con OpenAI", systemImage: "plus.circle")
            }
        } header: {
            Text("Otros proveedores")
        } footer: {
            Text("Cualquier API compatible con OpenAI (OpenAI, OpenRouter, Mistral, Together, un servidor local…), con su nombre, URL base y API key.")
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

    /// Pide la lista de modelos del proveedor (con la key ya guardada) y la guarda.
    private func loadModels(for provider: LLMProvider) async throws -> String {
        let models = try await GroqClient(apiKey: model.apiKey(for: provider), provider: provider).listModels()
        let ids = models.filter { $0.active ?? true }.map(\.id).sorted()
        let defaults = UserDefaults.standard
        let audioHints = ["whisper", "transcri", "speech-to-text", "stt"]
        let isAudio: (String) -> Bool = { id in audioHints.contains { id.localizedCaseInsensitiveContains($0) } }
        let message: String
        switch provider.id {
        case LLMProvider.groq.id:
            let transcription = ids.filter(isAudio)
            let excluded = ["whisper", "tts", "guard", "orpheus", "playai"]
            let chat = ids.filter { id in !excluded.contains { id.localizedCaseInsensitiveContains($0) } }
            defaults.set(transcription.joined(separator: "\n"), forKey: AppSettings.Key.fetchedTranscriptionModels(for: provider))
            defaults.set(chat.joined(separator: "\n"), forKey: AppSettings.Key.fetchedLLMModels(for: provider))
            message = "API key válida · \(transcription.count) modelos de audio y \(chat.count) de texto"
        case LLMProvider.google.id:
            let excluded = ["embedding", "imagen", "veo", "aqa", "tts", "image-generation", "native-audio", "live"]
            let chat = ids.filter { id in !excluded.contains { id.localizedCaseInsensitiveContains($0) } }
            defaults.set(chat.joined(separator: "\n"), forKey: AppSettings.Key.fetchedLLMModels(for: provider))
            message = "API key válida · \(chat.count) modelos de texto"
        default:
            // Proveedor personalizado: se muestran todos los modelos; los de audio también
            // para la transcripción (o todos si ninguno lo parece).
            let excluded = ["embed", "tts", "moderation", "dall-e", "image"]
            let chat = ids.filter { id in !excluded.contains { id.localizedCaseInsensitiveContains($0) } && !isAudio(id) }
            defaults.set((chat.isEmpty ? ids : chat).joined(separator: "\n"), forKey: AppSettings.Key.fetchedLLMModels(for: provider))
            if provider.supportsTranscription {
                let audio = ids.filter(isAudio)
                defaults.set((audio.isEmpty ? ids : audio).joined(separator: "\n"),
                             forKey: AppSettings.Key.fetchedTranscriptionModels(for: provider))
            }
            message = "Conexión correcta · \(ids.count) modelos"
        }
        revision += 1
        return message
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
            if let hint = provider.consoleHint {
                Text("La API key se guarda en el llavero del iPhone. Puedes crear una en \(hint).")
            } else {
                Text("La API key se guarda en el llavero del iPhone.")
            }
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

/// Alta y edición de un proveedor compatible con OpenAI.
struct CustomProviderEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let provider: LLMProvider?
    let load: (LLMProvider) async throws -> String

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var supportsTranscription = false
    @State private var revealKey = false
    @State private var status: APIKeySection.Status = .idle
    @State private var savedID: String? = nil
    @State private var confirmDelete = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var draft: LLMProvider {
        let id = savedID ?? provider?.id ?? "custom-\(UUID().uuidString)"
        return LLMProvider(id: id, name: trimmedName,
                           baseURLString: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                           supportsTranscription: supportsTranscription)
    }

    private var isValid: Bool { !trimmedName.isEmpty && draft.baseURL != nil }

    var body: some View {
        Form {
            Section {
                TextField("Nombre del proveedor", text: $name)
                TextField("https://api.ejemplo.com/v1", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Proveedor")
            } footer: {
                if !baseURL.isEmpty, draft.baseURL == nil {
                    Text("La URL no es válida: debe empezar con https:// (o http:// en la red local).")
                        .foregroundStyle(.red)
                } else {
                    Text("URL base de la API, la que normalmente acaba en /v1 (sin /chat/completions). Se usan <URL>/chat/completions, <URL>/models y, si lo activas, <URL>/audio/transcriptions.")
                }
            }

            Section {
                HStack {
                    Group {
                        if revealKey {
                            TextField("API key (opcional)", text: $apiKey)
                        } else {
                            SecureField("API key (opcional)", text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    Button {
                        revealKey.toggle()
                    } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("API key")
            } footer: {
                Text("Se envía como «Authorization: Bearer …» y se guarda en el llavero. Déjala vacía si el servidor no la pide.")
            }

            Section {
                Toggle("Admite transcripción de audio", isOn: $supportsTranscription)
            } footer: {
                Text("Actívalo si el proveedor ofrece /audio/transcriptions (p. ej. OpenAI con whisper-1) para poder elegirlo como proveedor de audio a texto.")
            }

            Section {
                Button {
                    Task { await saveAndTest() }
                } label: {
                    HStack {
                        Text("Guardar, probar y cargar modelos")
                        Spacer()
                        if status == .loading {
                            ProgressView()
                        }
                    }
                }
                .disabled(!isValid || status == .loading)
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
            }

            if provider != nil || savedID != nil {
                Section {
                    Button("Eliminar proveedor", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
        }
        .navigationTitle(provider == nil ? "Nuevo proveedor" : (provider?.name ?? "Proveedor"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Guardar") {
                    save()
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .confirmationDialog("¿Eliminar este proveedor?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) {
                model.deleteCustomProvider(draft)
                dismiss()
            }
        } message: {
            Text("Se borran su API key y su lista de modelos. Si estaba seleccionado, se vuelve a usar Groq.")
        }
        .onAppear {
            guard let provider, name.isEmpty, baseURL.isEmpty else { return }
            name = provider.name
            baseURL = provider.baseURLString
            supportsTranscription = provider.supportsTranscription
            apiKey = model.apiKey(for: provider)
        }
    }

    private func save() {
        guard isValid else { return }
        let saved = draft
        savedID = saved.id
        model.saveCustomProvider(saved)
        model.saveAPIKey(apiKey, for: saved)
    }

    private func saveAndTest() async {
        save()
        status = .loading
        do {
            status = .success(try await load(draft))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
