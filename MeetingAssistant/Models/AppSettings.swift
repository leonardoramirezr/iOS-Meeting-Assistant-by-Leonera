import Foundation

/// Duraciones de bloque disponibles en la configuración.
enum ChunkLength: Double, CaseIterable, Identifiable {
    case one = 60
    case twoAndHalf = 150
    case five = 300
    case ten = 600

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .one: return "1 min"
        case .twoAndHalf: return "2.5 min"
        case .five: return "5 min"
        case .ten: return "10 min"
        }
    }
}

/// Idioma que se envía a Whisper. Vacío = detección automática.
enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case automatic = ""
    case spanish = "es"
    case english = "en"
    case portuguese = "pt"
    case french = "fr"
    case german = "de"
    case italian = "it"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Detección automática"
        case .spanish: return "Español"
        case .english: return "Inglés"
        case .portuguese: return "Portugués"
        case .french: return "Francés"
        case .german: return "Alemán"
        case .italian: return "Italiano"
        }
    }
}

/// Proveedor de la API compatible con OpenAI que se usa para el LLM.
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case groq
    case google

    var id: String { rawValue }

    var label: String {
        switch self {
        case .groq: return "Groq"
        case .google: return "Google"
        }
    }

    var host: String {
        switch self {
        case .groq: return "api.groq.com"
        case .google: return "generativelanguage.googleapis.com"
        }
    }

    /// Base de la API compatible con OpenAI (termina en "/").
    var baseURL: URL {
        switch self {
        case .groq: return URL(string: "https://api.groq.com/openai/v1/")!
        case .google: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
        }
    }

    var chatURL: URL { URL(string: "chat/completions", relativeTo: baseURL)!.absoluteURL }
    var modelsURL: URL { URL(string: "models", relativeTo: baseURL)!.absoluteURL }

    /// Cuenta del llavero donde se guarda su API key.
    var keychainAccount: String {
        switch self {
        case .groq: return "groq-api-key"
        case .google: return "google-api-key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .groq: return "gsk_…"
        case .google: return "AIza…"
        }
    }

    var consoleHint: String {
        switch self {
        case .groq: return "console.groq.com/keys"
        case .google: return "aistudio.google.com/apikey"
        }
    }
}

/// Forma de procesar la minuta. Las opciones son mutuamente excluyentes.
enum ProcessingMode: String, CaseIterable, Identifiable, Codable {
    /// Lógica original: todas las transcripciones concatenadas en una sola petición.
    case fullTranscript
    /// Un resumen por bloque; la minuta se genera con los resúmenes concatenados.
    case perChunk
    /// Se agrupan N bloques, se resume cada grupo y la minuta sintetiza esos resúmenes.
    case mapReduce
    /// Resumen acumulativo: el modelo actualiza un resumen con cada bloque, en orden.
    case iterative

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullTranscript: return "Transcripción completa"
        case .perChunk: return "Resumir cada bloque"
        case .mapReduce: return "Agrupar bloques (Map-Reduce)"
        case .iterative: return "Resumen acumulativo"
        }
    }

    var detail: String {
        switch self {
        case .fullTranscript:
            return "Todos los bloques se envían concatenados en una sola petición para generar la minuta."
        case .perChunk:
            return "Se resume cada bloque por separado mientras se graba; la minuta se genera con los resúmenes concatenados."
        case .mapReduce:
            return "Se unen varios bloques consecutivos, se obtiene un resumen estructurado de cada grupo y la minuta se genera con esos resúmenes concatenados."
        case .iterative:
            return "Los bloques se procesan en orden: el modelo recibe el resumen acumulado y el siguiente bloque, y actualiza el resumen. La minuta se genera con el resumen final."
        }
    }

    var usesSummaries: Bool { self != .fullTranscript }
}

/// Configuración con la que se generaron los resúmenes de una reunión.
struct SummaryPlan: Codable, Hashable {
    var mode: ProcessingMode
    /// Bloques por segmento (1 salvo en Map-Reduce).
    var groupSize: Int
}

/// Tiempo de espera tras un error de límite de cuota (429).
enum QuotaPause: Double, CaseIterable, Identifiable {
    case one = 60
    case two = 120
    case five = 300
    case ten = 600
    case fifteen = 900
    case thirty = 1800
    case sixty = 3600

    var id: Double { rawValue }

    var label: String {
        let minutes = Int(rawValue / 60)
        return minutes == 60 ? "1 hora" : "\(minutes) min"
    }
}

/// Preferencias de la app guardadas en `UserDefaults` (la API key va en el llavero).
enum AppSettings {
    enum Key {
        static let transcriptionModel = "settings.transcriptionModel"
        /// Modelo LLM de Groq (clave histórica).
        static let llmModel = "settings.llmModel"
        static let googleLLMModel = "settings.googleLLMModel"
        static let llmProvider = "settings.llmProvider"
        static let fetchedGoogleModels = "settings.fetchedGoogleModels"
        static let chunkLength = "settings.chunkLength"
        static let language = "settings.language"
        static let minutesPrompt = "settings.minutesPrompt"
        static let autoGenerateMinutes = "settings.autoGenerateMinutes"
        static let fetchedTranscriptionModels = "settings.fetchedTranscriptionModels"
        static let fetchedLLMModels = "settings.fetchedLLMModels"
        static let processingMode = "settings.processingMode"
        static let mapReduceGroupSize = "settings.mapReduceGroupSize"
        static let quotaPause = "settings.quotaPause"
        /// Fin de la pausa por cuota en curso (timestamp), para reanudar tras reiniciar la app.
        static let pausedUntil = "processing.pausedUntil"
        static let pauseReason = "processing.pauseReason"
        static let preventiveRateLimitPause = "settings.preventiveRateLimitPause"
        static let rateLimitTokenThreshold = "settings.rateLimitTokenThreshold"
    }

    static let defaultTranscriptionModel = "whisper-large-v3-turbo"
    static let defaultLLMModel = "openai/gpt-oss-120b"
    static let defaultGoogleLLMModel = "gemini-2.5-flash"
    static let defaultLLMProvider = LLMProvider.groq.rawValue
    static let defaultChunkLength = ChunkLength.five.rawValue
    static let defaultLanguage = TranscriptionLanguage.spanish.rawValue

    static let defaultProcessingMode = ProcessingMode.fullTranscript.rawValue
    static let defaultMapReduceGroupSize = 5
    static let mapReduceGroupSizeRange = 2...30
    static let defaultQuotaPause = QuotaPause.two.rawValue
    static let defaultRateLimitTokenThreshold = 1000

    /// Separador entre resúmenes de segmentos en la petición de la minuta.
    static let summaryBoundary = "[SEGMENT SUMMARY BOUNDARY]"

    /// Duración máxima de una grabación.
    static let maxRecordingDuration: TimeInterval = 3 * 60 * 60

    /// Separador entre las transcripciones de bloques consecutivos.
    static let chunkBoundary = "[TRANSCRIPTION CHUNK BOUNDARY]"

    static let suggestedTranscriptionModels = [
        "whisper-large-v3-turbo",
        "whisper-large-v3",
    ]

    static let suggestedGoogleModels = [
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.5-flash-lite",
    ]

    static let suggestedLLMModels = [
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b",
        "llama-3.3-70b-versatile",
        "meta-llama/llama-4-maverick-17b-128e-instruct",
        "meta-llama/llama-4-scout-17b-16e-instruct",
        "moonshotai/kimi-k2-instruct-0905",
        "qwen/qwen3-32b",
        "llama-3.1-8b-instant",
    ]

    static let defaultMinutesPrompt = """
    Eres un asistente experto en redactar minutas de reuniones de trabajo.

    A continuación recibirás la transcripción automática (Whisper) de una reunión. El audio se grabó y se transcribió en bloques consecutivos: la etiqueta [TRANSCRIPTION CHUNK BOUNDARY] marca el punto donde termina un bloque y empieza el siguiente, así que una frase puede quedar partida en ese punto; trátalo todo como una sola conversación continua. La transcripción no indica quién habla y puede contener errores de reconocimiento: corrígelos solo cuando el contexto lo deje claro, ignora frases que sean artefactos evidentes de la transcripción (por ejemplo «Gracias por ver el video» o «Subtítulos realizados por la comunidad de Amara.org») y no inventes información que no aparezca en ella.

    Redacta la minuta en español, en formato Markdown, con exactamente estas secciones y en este orden:

    # Minuta de la reunión

    ## Datos generales
    - **Tema principal:** una línea.
    - **Participantes mencionados:** nombres y, si se menciona, su rol; si no es posible identificarlos, escribe «No identificados».

    ## Resumen ejecutivo
    Un párrafo de 3 a 6 oraciones con el propósito de la reunión y sus conclusiones principales.

    ## Temas tratados
    Un subtítulo (###) por cada tema, en el orden en que se trataron, con viñetas que recojan los puntos clave, las posturas expresadas y los datos, cifras o fechas mencionados.

    ## Decisiones tomadas
    Lista numerada con las decisiones concretas. Si no se tomó ninguna, escribe «No se registraron decisiones».

    ## Riesgos y preguntas abiertas
    Viñetas con los riesgos, dudas o temas que quedaron sin resolver. Si no hay, escribe «Ninguno».

    ## Acuerdos y asuntos pendientes
    Tabla Markdown con las columnas | Acuerdo o pendiente | Responsable | Fecha límite |. Usa «Por definir» cuando no se mencione el responsable o la fecha. Esta debe ser la última sección de la minuta: no añadas nada después de ella.

    Transcripción:
    """

    /// Prompt para resumir un bloque o un grupo de bloques (modos "Resumir cada bloque" y Map-Reduce).
    static let segmentSummaryPrompt = """
    Eres un asistente que resume fragmentos de reuniones de trabajo para redactar después una minuta.

    A continuación recibirás un fragmento de la transcripción automática (Whisper) de una reunión. Puede estar formado por varios bloques consecutivos separados por [TRANSCRIPTION CHUNK BOUNDARY]; una frase puede quedar partida en esos puntos. La transcripción no indica quién habla y puede tener errores de reconocimiento: corrígelos solo cuando el contexto lo deje claro, ignora artefactos evidentes (como «Gracias por ver el video») y no inventes nada.

    Devuelve un resumen estructurado en español, en Markdown, con estas secciones (omite las que no tengan contenido):
    - **Temas:** temas tratados en el fragmento.
    - **Puntos clave:** ideas, posturas y argumentos relevantes.
    - **Datos y cifras:** números, fechas, nombres propios mencionados.
    - **Decisiones:** decisiones concretas tomadas.
    - **Acuerdos y pendientes:** tareas o compromisos, con responsable y fecha si se mencionan.

    Si el fragmento no tiene contenido relevante, responde solo «Sin contenido relevante».
    """

    /// Prompt del resumen acumulativo (iterative refinement).
    static let iterativeSummaryPrompt = """
    Eres un asistente que mantiene actualizado el resumen de una reunión de trabajo mientras avanza.

    Recibirás el RESUMEN ACUMULADO hasta ahora (vacío al empezar) y el SIGUIENTE SEGMENTO de la transcripción automática (Whisper). El segmento puede empezar o terminar con frases partidas; la transcripción no indica quién habla y puede tener errores de reconocimiento: corrígelos solo cuando el contexto lo deje claro, ignora artefactos evidentes y no inventes nada.

    Devuelve el resumen acumulado actualizado, en español y en Markdown: integra la información nueva, conserva todo lo importante del resumen anterior (no lo acortes ni pierdas detalles relevantes), corrige lo que el nuevo segmento aclare y mantén el orden cronológico. Usa estas secciones:
    - **Temas tratados:** en orden, con sus puntos clave, posturas y datos o cifras.
    - **Decisiones:** decisiones concretas tomadas.
    - **Acuerdos y pendientes:** tareas o compromisos, con responsable y fecha si se mencionan.
    - **Preguntas abiertas:** temas sin resolver.

    Responde solo con el resumen actualizado.
    """

    /// Aclaración que precede a los resúmenes cuando la minuta no se genera con la transcripción literal.
    static let summariesNote = "Nota: en lugar de la transcripción literal, a continuación se incluyen resúmenes consecutivos de la reunión, en orden cronológico y separados por [SEGMENT SUMMARY BOUNDARY]. Úsalos como si fueran la transcripción."
    static let iterativeNote = "Nota: en lugar de la transcripción literal, a continuación se incluye un resumen acumulativo de toda la reunión, construido en orden cronológico. Úsalo como si fuera la transcripción."

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.transcriptionModel: defaultTranscriptionModel,
            Key.llmModel: defaultLLMModel,
            Key.googleLLMModel: defaultGoogleLLMModel,
            Key.llmProvider: defaultLLMProvider,
            Key.chunkLength: defaultChunkLength,
            Key.language: defaultLanguage,
            Key.minutesPrompt: defaultMinutesPrompt,
            Key.autoGenerateMinutes: true,
            Key.processingMode: defaultProcessingMode,
            Key.mapReduceGroupSize: defaultMapReduceGroupSize,
            Key.quotaPause: defaultQuotaPause,
            Key.preventiveRateLimitPause: true,
            Key.rateLimitTokenThreshold: defaultRateLimitTokenThreshold,
        ])
    }

    static var transcriptionModel: String {
        nonEmpty(defaults.string(forKey: Key.transcriptionModel)) ?? defaultTranscriptionModel
    }

    static var llmProvider: LLMProvider {
        LLMProvider(rawValue: defaults.string(forKey: Key.llmProvider) ?? "") ?? .groq
    }

    /// Modelo LLM del proveedor seleccionado.
    static var llmModel: String {
        llmModel(for: llmProvider)
    }

    static func llmModel(for provider: LLMProvider) -> String {
        switch provider {
        case .groq:
            return nonEmpty(defaults.string(forKey: Key.llmModel)) ?? defaultLLMModel
        case .google:
            return nonEmpty(defaults.string(forKey: Key.googleLLMModel)) ?? defaultGoogleLLMModel
        }
    }

    static var chunkLength: TimeInterval {
        let value = defaults.double(forKey: Key.chunkLength)
        return ChunkLength(rawValue: value)?.rawValue ?? defaultChunkLength
    }

    /// Código ISO-639-1 o `nil` para detección automática.
    static var transcriptionLanguage: String? {
        nonEmpty(defaults.string(forKey: Key.language))
    }

    static var minutesPrompt: String {
        nonEmpty(defaults.string(forKey: Key.minutesPrompt)) ?? defaultMinutesPrompt
    }

    static var autoGenerateMinutes: Bool {
        defaults.bool(forKey: Key.autoGenerateMinutes)
    }

    static var processingMode: ProcessingMode {
        ProcessingMode(rawValue: defaults.string(forKey: Key.processingMode) ?? "") ?? .fullTranscript
    }

    static var mapReduceGroupSize: Int {
        let value = defaults.integer(forKey: Key.mapReduceGroupSize)
        return mapReduceGroupSizeRange.contains(value) ? value : defaultMapReduceGroupSize
    }

    /// Plan actual: el tamaño de grupo solo cuenta en Map-Reduce.
    static var summaryPlan: SummaryPlan {
        let mode = processingMode
        return SummaryPlan(mode: mode, groupSize: mode == .mapReduce ? mapReduceGroupSize : 1)
    }

    static var quotaPause: TimeInterval {
        QuotaPause(rawValue: defaults.double(forKey: Key.quotaPause))?.rawValue ?? defaultQuotaPause
    }

    /// Pausar antes de agotar los tokens cuando `x-ratelimit-remaining-tokens` baja del umbral.
    static var preventiveRateLimitPause: Bool {
        defaults.bool(forKey: Key.preventiveRateLimitPause)
    }

    static var rateLimitTokenThreshold: Int {
        max(defaults.integer(forKey: Key.rateLimitTokenThreshold), 0)
    }

    static var pauseReason: String? {
        get { defaults.string(forKey: Key.pauseReason) }
        set { defaults.set(newValue, forKey: Key.pauseReason) }
    }

    static var pausedUntil: Date? {
        get {
            let value = defaults.double(forKey: Key.pausedUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.pausedUntil)
            } else {
                defaults.removeObject(forKey: Key.pausedUntil)
            }
        }
    }

    /// Lista guardada (separada por saltos de línea) de modelos obtenidos de la API.
    static func storedModelList(_ raw: String) -> [String] {
        raw.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
