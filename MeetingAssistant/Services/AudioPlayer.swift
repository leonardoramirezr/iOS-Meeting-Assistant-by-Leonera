import AVFoundation
import Observation

/// Reproduce un bloque de audio para revisarlo.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var playingURL: URL? = nil
    private(set) var errorMessage: String? = nil
    @ObservationIgnored private var player: AVAudioPlayer? = nil
    private let delegate = PlayerDelegate()

    init() {
        delegate.onFinish = { [weak self] in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = delegate
            player.play()
            self.player = player
            playingURL = url
            errorMessage = nil
        } catch {
            errorMessage = "No se pudo reproducir el audio: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        playingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)? = nil
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
