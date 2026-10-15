import AVFoundation
import Foundation
import Observation

/// Clip ya cerrado y listo para enviarse a Whisper.
struct RecordedChunk: Sendable {
    let index: Int
    let url: URL
    let duration: TimeInterval
}

enum RecorderError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: return "No hay ningún micrófono disponible."
        }
    }
}

/// Escribe el audio del micrófono en archivos AAC consecutivos.
///
/// Recibe los buffers del tap de `AVAudioEngine` (hilo de audio) y, cuando el
/// bloque actual alcanza la duración configurada, cierra ese archivo y empieza
/// otro con el siguiente buffer: la grabación no se detiene y no se pierde audio
/// entre bloques.
final class ChunkFileWriter: @unchecked Sendable {
    struct Snapshot {
        var recordedDuration: TimeInterval = 0
        var chunkIndex = 0
        var chunkElapsed: TimeInterval = 0
        var level: Float = 0
        var lastError: String? = nil
    }

    private let lock = NSLock()
    private let directory: URL
    private let chunkDuration: TimeInterval
    private let onChunk: @Sendable (RecordedChunk) -> Void

    private var file: AVAudioFile? = nil
    private var fileURL: URL? = nil
    private var sampleRate: Double = 0
    private var channelCount: AVAudioChannelCount = 0
    private var chunkIndex = 0
    private var chunkFrames: AVAudioFramePosition = 0
    private var finishedDuration: TimeInterval = 0
    private var level: Float = 0
    private var lastError: String? = nil
    private var isFinished = false

    /// `onChunk` se llama en el hilo de audio, en orden y con el archivo ya cerrado.
    init(directory: URL, chunkDuration: TimeInterval, onChunk: @escaping @Sendable (RecordedChunk) -> Void) {
        self.directory = directory
        self.chunkDuration = chunkDuration
        self.onChunk = onChunk
    }

    var tapBlock: AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            self?.append(buffer)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, buffer.frameLength > 0 else { return }

        // Si la ruta de audio cambió de formato (p. ej. al conectar unos audífonos)
        // se cierra el bloque actual y se empieza otro con el formato nuevo.
        if file != nil,
           buffer.format.sampleRate != sampleRate || buffer.format.channelCount != channelCount {
            closeCurrentFile()
        }

        do {
            if file == nil {
                try openFile(for: buffer.format)
            }
            guard let file else { return }
            try autoreleasepool {
                try file.write(from: buffer)
            }
            chunkFrames += AVAudioFramePosition(buffer.frameLength)
            level = Self.level(of: buffer)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }

        if Double(chunkFrames) >= chunkDuration * sampleRate {
            closeCurrentFile()
        }
    }

    /// Cierra el bloque en curso. A partir de aquí se ignoran los buffers que lleguen.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        closeCurrentFile()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let current = sampleRate > 0 ? Double(chunkFrames) / sampleRate : 0
        return Snapshot(
            recordedDuration: finishedDuration + current,
            chunkIndex: chunkIndex,
            chunkElapsed: current,
            level: level,
            lastError: lastError
        )
    }

    // MARK: Privado (siempre con `lock` tomado)

    private func openFile(for format: AVAudioFormat) throws {
        let url = directory.appendingPathComponent(String(format: "chunk-%03d.m4a", chunkIndex + 1))
        try? FileManager.default.removeItem(at: url)

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: Self.bitRate(sampleRate: format.sampleRate, channels: format.channelCount),
        ]
        let newFile: AVAudioFile
        do {
            newFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            // Algunas combinaciones de frecuencia/bitrate no son válidas para AAC:
            // se deja que el codificador elija el bitrate.
            settings.removeValue(forKey: AVEncoderBitRateKey)
            newFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        file = newFile
        fileURL = url
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        chunkFrames = 0
    }

    private func closeCurrentFile() {
        guard file != nil, let url = fileURL else { return }
        if #available(iOS 18.0, *) {
            file?.close()
        }
        // Liberar el AVAudioFile termina de escribir el contenedor .m4a.
        file = nil
        fileURL = nil

        let duration = sampleRate > 0 ? Double(chunkFrames) / sampleRate : 0
        chunkFrames = 0
        guard duration >= 1 else {
            // Fragmentos de menos de un segundo (p. ej. al detener justo después de un corte).
            try? FileManager.default.removeItem(at: url)
            return
        }
        finishedDuration += duration
        let chunk = RecordedChunk(index: chunkIndex, url: url, duration: duration)
        chunkIndex += 1
        onChunk(chunk)
    }

    private static func bitRate(sampleRate: Double, channels: AVAudioChannelCount) -> Int {
        let perChannel: Int
        switch sampleRate {
        case 44_100...: perChannel = 64_000
        case 32_000...: perChannel = 48_000
        case 22_050...: perChannel = 32_000
        default: perChannel = 24_000
        }
        return perChannel * Int(max(channels, 1))
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for i in 0..<count {
            sum += samples[i] * samples[i]
        }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 55) / 55, 0), 1)
    }
}

/// Graba el micrófono con `AVAudioEngine` y lo divide en bloques de duración fija.
@MainActor
@Observable
final class AudioChunkRecorder {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    private(set) var state: State = .idle
    private(set) var recordedDuration: TimeInterval = 0
    private(set) var chunkIndex = 0
    private(set) var chunkElapsed: TimeInterval = 0
    private(set) var chunkDuration: TimeInterval = AppSettings.defaultChunkLength
    private(set) var level: Float = 0
    private(set) var statusMessage: String? = nil
    /// Motivo por el que la grabación se detuvo sola (p. ej. límite de 3 h).
    private(set) var autoStopReason: String? = nil
    let maxDuration = AppSettings.maxRecordingDuration

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var writer: ChunkFileWriter? = nil
    @ObservationIgnored private var timer: Timer? = nil
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var onStop: (@MainActor @Sendable () -> Void)? = nil
    init() {
        observeAudioSession()
    }

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Empieza a grabar. `onChunk` recibe cada bloque cerrado y `onStop` se llama
    /// al terminar, siempre después del último `onChunk`.
    func start(
        directory: URL,
        chunkDuration: TimeInterval,
        onChunk: @escaping @MainActor @Sendable (RecordedChunk) -> Void,
        onStop: @escaping @MainActor @Sendable () -> Void
    ) throws {
        guard state == .idle else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try activateSession()

        let writer = ChunkFileWriter(directory: directory, chunkDuration: chunkDuration) { chunk in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onChunk(chunk) }
            }
        }
        self.writer = writer
        self.onStop = onStop
        self.chunkDuration = chunkDuration
        recordedDuration = 0
        chunkIndex = 0
        chunkElapsed = 0
        statusMessage = nil
        autoStopReason = nil

        do {
            try startEngine()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.writer = nil
            self.onStop = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        state = .recording
        startTimer()
    }

    func pause() {
        guard state == .recording else { return }
        engine.stop()
        state = .paused
        level = 0
    }

    func resume() {
        guard state == .paused else { return }
        do {
            try activateSession()
            try startEngine()
            state = .recording
            statusMessage = nil
        } catch {
            statusMessage = "No se pudo reanudar la grabación: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard state != .idle else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.finish()
        refreshStats()
        writer = nil
        timer?.invalidate()
        timer = nil
        state = .idle
        level = 0
        resumeAfterInterruption = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // Los bloques se entregan en la cola principal; `onStop` va detrás de todos.
        if let onStop {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onStop() }
            }
        }
        onStop = nil
    }

    // MARK: Motor de audio

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
    }

    private func startEngine() throws {
        guard let writer else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: writer.tapBlock)
        engine.prepare()
        try engine.start()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStats()
                self?.enforceMaxDuration()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refreshStats() {
        guard let writer else { return }
        let snapshot = writer.snapshot()
        recordedDuration = snapshot.recordedDuration
        chunkIndex = snapshot.chunkIndex
        chunkElapsed = snapshot.chunkElapsed
        level = state == .recording ? snapshot.level : 0
        if let error = snapshot.lastError {
            statusMessage = "Error al escribir el audio: \(error)"
        }
    }

    private func enforceMaxDuration() {
        guard state != .idle, recordedDuration >= maxDuration else { return }
        autoStopReason = "La grabación se detuvo automáticamente al llegar al máximo de 3 horas."
        stop()
    }

    // MARK: Interrupciones y cambios de ruta

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: type)
            }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMediaServicesReset()
            }
        })
    }

    private func handleInterruption(typeValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            guard state == .recording else { return }
            engine.stop()
            state = .paused
            level = 0
            resumeAfterInterruption = true
            statusMessage = "Grabación en pausa por una interrupción (llamada, alarma…)."
        case .ended:
            guard resumeAfterInterruption, state == .paused else { return }
            resumeAfterInterruption = false
            resume()
        @unknown default:
            break
        }
    }

    private func handleConfigurationChange() {
        guard state == .recording else { return }
        do {
            try startEngine()
        } catch {
            state = .paused
            level = 0
            statusMessage = "La entrada de audio cambió y la grabación quedó en pausa: \(error.localizedDescription)"
        }
    }

    private func handleMediaServicesReset() {
        guard state != .idle else { return }
        engine = AVAudioEngine()
        let wasRecording = state == .recording
        state = .paused
        if wasRecording {
            resume()
        }
    }
}
