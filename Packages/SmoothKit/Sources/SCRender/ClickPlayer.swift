import AVFoundation
import SCCore

/// Plays the click sound live in the preview, in step with the cursor's clicks.
@MainActor
final class ClickPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: ClickSound.sampleRate, channels: 1)!
        let samples = ClickSound.samples
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        if let buffer, let data = buffer.floatChannelData?[0] {
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: samples.count) }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Starts the audio engine ahead of the first click so it plays without delay.
    func prepare() {
        guard !engine.isRunning else { return }
        try? engine.start()
        player.play()
    }

    func play(volume: Double) {
        prepare()
        guard let buffer, engine.isRunning else { return }
        player.volume = Float(min(max(volume, 0), 2))
        player.scheduleBuffer(buffer, at: nil, options: [])
    }

    func stop() {
        guard engine.isRunning else { return }
        player.stop()
        engine.pause()
    }
}
