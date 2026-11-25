import AVFoundation
import QuartzCore

/// Gameplay clock. Uses the audio device clock when a track is available, otherwise the media clock.
/// Time is milliseconds relative to the start of the audio file; it is negative during the pre-roll.
final class GameClock {
    private var player: AVAudioPlayer?
    private var startDevice: TimeInterval = 0
    private var fallbackStart: CFTimeInterval = 0
    private let preRollSeconds: Double = 2.0

    /// Positive values shift hit objects later relative to the audio (UNCALIBRATED, user-adjustable).
    var offsetMs: Double = 0

    init(audioURL: URL?) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let audioURL {
            player = try? AVAudioPlayer(contentsOf: audioURL)
            player?.prepareToPlay()
        }
    }

    var hasAudio: Bool { player != nil }

    func start() {
        if let player {
            startDevice = player.deviceCurrentTime + preRollSeconds
            player.play(atTime: startDevice)
        } else {
            fallbackStart = CACurrentMediaTime() + preRollSeconds
        }
    }

    var timeMs: Double {
        if let player { return (player.deviceCurrentTime - startDevice) * 1000 - offsetMs }
        return (CACurrentMediaTime() - fallbackStart) * 1000 - offsetMs
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
