@preconcurrency import AVFoundation
import Foundation
import SCCore
import Speech

/// On-device captions with SpeechAnalyzer: words with timings, grouped into readable lines.
public enum Transcriber {
    public enum Failure: LocalizedError {
        case noAudio, unsupportedLanguage(String)
        public var errorDescription: String? {
            switch self {
            case .noAudio: "This recording has no audio to transcribe."
            case let .unsupportedLanguage(code): "Captions aren't available for \(code) on this Mac."
            }
        }
    }

    public static func supportedLanguages() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    /// - Parameter preferredTrack: audio track to transcribe (e.g. the microphone); nil mixes all tracks.
    public static func transcribe(
        videoURL: URL, preferredTrack: Int?, locale: Locale, progress: @escaping @Sendable (String) -> Void
    ) async throws -> [CaptionSegment] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLanguage(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("Downloading language model…")
            try await request.downloadAndInstall()
        }

        progress("Preparing audio…")
        let audioURL = try await extractAudio(from: videoURL, track: preferredTrack)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        progress("Transcribing…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [(text: String, range: TimeRange)] in
            var words: [(String, TimeRange)] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    guard let r = run.audioTimeRange, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    words.append((text, TimeRange(start: r.start.seconds, end: r.end.seconds)))
                }
            }
            return words.map { (text: $0.0, range: $0.1) }
        }
        let file = try AVAudioFile(forReading: audioURL)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let words = try await collector.value
        return group(words)
    }

    /// Lines of ≤ 42 characters and ≤ 3.5 s, breaking at pauses and sentence ends.
    static func group(_ words: [(text: String, range: TimeRange)]) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        var text = ""
        var start: Seconds?
        var end: Seconds = 0
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = start, !trimmed.isEmpty { segments.append(CaptionSegment(range: TimeRange(start: s, end: max(end, s + 0.6)), text: trimmed)) }
            text = ""
            start = nil
        }
        for w in words {
            let piece = w.text
            if let s = start {
                let pause = w.range.start - end
                if pause > 0.7 || (text + piece).count > 42 || w.range.end - s > 3.5 { flush() }
            }
            if start == nil { start = w.range.start }
            text += piece
            end = w.range.end
            if let last = piece.trimmingCharacters(in: .whitespaces).last, ".?!".contains(last), text.count > 6 { flush() }
        }
        flush()
        // A lone short word at the end of a line reads better merged into the previous line.
        var merged: [CaptionSegment] = []
        for s in segments {
            if let prev = merged.last, s.text.count < 9, s.range.start - prev.range.end < 0.4, prev.text.count + s.text.count < 50 {
                merged[merged.count - 1].text += " " + s.text
                merged[merged.count - 1].range.end = s.range.end
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    /// 16 kHz mono float CAF of one track (or the mix), for the analyzer.
    static func extractAudio(from url: URL, track: Int?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        var tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure.noAudio }
        if let track, tracks.indices.contains(track) { tracks = [tracks[track]] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.noAudio }

        let out = FileManager.default.temporaryDirectory.appending(path: "captions-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { throw Failure.noAudio }
        let file = try AVAudioFile(forWriting: out, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 4, destination: buffer.floatChannelData![0])
            try file.write(from: buffer)
        }
        return out
    }
}
