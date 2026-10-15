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

/// Preferencias de la app guardadas en `UserDefaults` (la API key va en el llavero).
enum AppSettings {
    enum Key {
        static let transcriptionModel = "settings.transcriptionModel"
        static let llmModel = "settings.llmModel"
        static let chunkLength = "settings.chunkLength"
        static let language = "settings.language"
        static let minutesPrompt = "settings.minutesPrompt"
        static let autoGenerateMinutes = "settings.autoGenerateMinutes"
        static let fetchedTranscriptionModels = "settings.fetchedTranscriptionModels"
        static let fetchedLLMModels = "settings.fetchedLLMModels"
    }

    static let defaultTranscriptionModel = "whisper-large-v3-turbo"
    static let defaultLLMModel = "openai/gpt-oss-120b"
    static let defaultChunkLength = ChunkLength.five.rawValue
    static let defaultLanguage = TranscriptionLanguage.spanish.rawValue

    /// Duración máxima de una grabación.
    static let maxRecordingDuration: TimeInterval = 3 * 60 * 60

    /// Separador entre las transcripciones de bloques consecutivos.
    static let chunkBoundary = "[TRANSCRIPTION CHUNK BOUNDARY]"

    static let suggestedTranscriptionModels = [
        "whisper-large-v3-turbo",
        "whisper-large-v3",
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

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.transcriptionModel: defaultTranscriptionModel,
            Key.llmModel: defaultLLMModel,
            Key.chunkLength: defaultChunkLength,
            Key.language: defaultLanguage,
            Key.minutesPrompt: defaultMinutesPrompt,
            Key.autoGenerateMinutes: true,
        ])
    }

    static var transcriptionModel: String {
        nonEmpty(defaults.string(forKey: Key.transcriptionModel)) ?? defaultTranscriptionModel
    }

    static var llmModel: String {
        nonEmpty(defaults.string(forKey: Key.llmModel)) ?? defaultLLMModel
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
