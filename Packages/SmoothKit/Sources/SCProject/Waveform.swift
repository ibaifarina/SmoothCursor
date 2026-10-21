import AVFoundation
import Foundation

/// Peak envelope of all audio tracks mixed, for the timeline.
public enum Waveform {
    /// Peaks (0...1) at `rate` buckets per second. Empty when the file has no audio.
    public static func peaks(of url: URL, rate: Double = 100) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        // Low sample rate mono float: plenty for an envelope, and fast.
        let sampleRate = 8_000.0
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let bucket = max(Int(sampleRate / rate), 1)
        var peaks: [Float] = []
        var current: Float = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for v in data {
                current = max(current, abs(v))
                count += 1
                if count == bucket {
                    peaks.append(current)
                    current = 0
                    count = 0
                }
            }
            if Task.isCancelled { reader.cancelReading(); return [] }
        }
        if count > 0 { peaks.append(current) }
        // Normalize with a gentle curve so quiet narration is still visible.
        let top = max(peaks.max() ?? 1, 0.05)
        return peaks.map { pow(min($0 / top, 1), 0.6) }
    }
}
