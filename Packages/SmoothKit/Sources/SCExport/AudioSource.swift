@preconcurrency import AVFoundation
import Foundation
import SCCore

/// Audio for an export: the composition's tracks mixed to 48 kHz stereo float, with click sounds
/// mixed in — or, for silent recordings with click sounds on, synthesized silence + clicks.
final class AudioSource: @unchecked Sendable {
    static let sampleRate = 48_000.0
    private static var settings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ] }

    private let reader: AVAssetReader?
    private let output: AVAssetReaderAudioMixOutput?
    private let clicks: [Seconds]
    private let clickGain: Float
    private let synthesizedDuration: Seconds
    private var synthesizedFrames = 0
    private lazy var format: CMAudioFormatDescription? = Self.makeFormat()

    init(tracks: [AVAssetTrack], composition: AVAsset, clicks: [Seconds], clickVolume: Double = 1, volumes: [Double]) throws {
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: Self.settings)
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { i, track in
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(Float(i < volumes.count ? volumes[i] : 1), at: .zero)
            return p
        }
        output.audioMix = mix
        reader.add(output)
        self.reader = reader
        self.output = output
        self.clicks = clicks.sorted()
        clickGain = Float(max(clickVolume, 0))
        synthesizedDuration = 0
    }

    init(synthesizing duration: Seconds, clicks: [Seconds], clickVolume: Double = 1) {
        reader = nil
        output = nil
        self.clicks = clicks.sorted()
        clickGain = Float(max(clickVolume, 0))
        synthesizedDuration = duration
    }

    func start() throws {
        if let reader, !reader.startReading() { throw reader.error ?? CocoaError(.fileReadUnknown) }
    }

    func stop() { reader?.cancelReading() }

    func next() -> CMSampleBuffer? {
        if let output {
            guard let sample = output.copyNextSampleBuffer() else { return nil }
            return mixClicks(into: sample)
        }
        // Synthesized: 4096-frame buffers of silence with clicks.
        let total = Int(synthesizedDuration * Self.sampleRate)
        guard synthesizedFrames < total, let format else { return nil }
        let count = min(4096, total - synthesizedFrames)
        var data = [Float](repeating: 0, count: count * 2)
        let start = Double(synthesizedFrames) / Self.sampleRate
        addClicks(to: &data, frames: count, start: start)
        synthesizedFrames += count
        return Self.makeBuffer(data, frames: count, pts: CMTime(value: CMTimeValue(synthesizedFrames - count), timescale: 48_000), format: format)
    }

    // MARK: Clicks

    private static var click: [Float] { ClickSound.samples }

    private func addClicks(to data: inout [Float], frames: Int, start: Seconds) {
        let end = start + Double(frames) / Self.sampleRate
        let length = Double(Self.click.count) / Self.sampleRate
        for c in clicks where c < end && c + length > start {
            let offset = Int(((c - start) * Self.sampleRate).rounded())
            for (j, v) in Self.click.enumerated() {
                let i = offset + j
                guard i >= 0, i < frames else { continue }
                data[2 * i] += v * clickGain
                data[2 * i + 1] += v * clickGain
            }
        }
    }

    private func mixClicks(into sample: CMSampleBuffer) -> CMSampleBuffer {
        guard !clicks.isEmpty, let block = sample.dataBuffer, let format = sample.formatDescription else { return sample }
        let frames = CMSampleBufferGetNumSamples(sample)
        let start = sample.presentationTimeStamp.seconds
        let length = Double(Self.click.count) / Self.sampleRate
        let end = start + Double(frames) / Self.sampleRate
        guard clicks.contains(where: { $0 < end && $0 + length > start }) else { return sample }
        var data = [Float](repeating: 0, count: frames * 2)
        _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: min($0.count, CMBlockBufferGetDataLength(block)), destination: $0.baseAddress!) }
        addClicks(to: &data, frames: frames, start: start)
        return Self.makeBuffer(data, frames: frames, pts: sample.presentationTimeStamp, format: format) ?? sample
    }

    // MARK: Buffers

    private static func makeFormat() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format
    }

    private static func makeBuffer(_ data: [Float], frames: Int, pts: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = data.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}
