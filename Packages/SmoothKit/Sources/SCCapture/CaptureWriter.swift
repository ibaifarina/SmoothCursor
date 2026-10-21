import AVFoundation
import CoreMedia
import SCCore
import VideoToolbox

/// Hardware-encoded writer for live capture. Not thread-safe: every call must come from the
/// owning engine's sample queue. Timestamps are host-clock and are mapped through `RecordingClock`.
final class CaptureWriter: @unchecked Sendable {
    enum AudioSlot: Hashable { case system, microphone, device }

    struct VideoFormat {
        var width: Int
        var height: Int
        var fps: Int
        var codec: VideoCodec
        var quality: Double
    }

    let url: URL
    let clock: RecordingClock
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInputs: [AudioSlot: AVAssetWriterInput]
    private let frameDuration: CMTime
    private var sessionStarted = false
    private var lastVideo: CMSampleBuffer?
    private var lastVideoTime = CMTime.negativeInfinity
    private(set) var framesWritten = 0
    private(set) var framesDropped = 0

    var error: Error? { writer.status == .failed ? writer.error : nil }

    init(url: URL, video: VideoFormat, audio: [AudioSlot: Int], clock: RecordingClock) throws {
        self.url = url
        self.clock = clock
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, video.fps)))
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600) // crash-safe partial files

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(video))
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw CaptureError.writerSetup("video") }
        writer.add(videoInput)

        var inputs: [AudioSlot: AVAssetWriterInput] = [:]
        // Deterministic track order: system, microphone, device.
        for slot in [AudioSlot.system, .microphone, .device] {
            guard let channels = audio[slot] else { continue }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: channels))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureError.writerSetup("audio") }
            writer.add(input)
            inputs[slot] = input
        }
        audioInputs = inputs

        guard writer.startWriting() else { throw writer.error ?? CaptureError.writerSetup("start") }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        let host = sample.presentationTimeStamp
        if clock.startIfNeeded(at: host) {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        guard sessionStarted, let t = clock.mediaTime(forHost: host), t > lastVideoTime else { return }
        guard videoInput.isReadyForMoreMediaData, let retimed = sample.retimed(to: t) else {
            framesDropped += 1
            return
        }
        if videoInput.append(retimed) {
            framesWritten += 1
            lastVideo = retimed
            lastVideoTime = t
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, slot: AudioSlot) {
        guard sessionStarted, let input = audioInputs[slot], input.isReadyForMoreMediaData,
              let t = clock.mediaTime(forHost: sample.presentationTimeStamp),
              let retimed = sample.retimed(to: t) else { return }
        input.append(retimed)
    }

    /// Finishes the file. Holds the last frame until `end` so static screens keep their full length.
    /// Returns the media duration.
    func finish(end: CMTime) async throws -> CMTime {
        guard sessionStarted else {
            writer.cancelWriting()
            throw CaptureError.noFrames
        }
        let endTime = CMTimeMaximum(end, lastVideoTime + frameDuration)
        let holdTime = endTime - frameDuration
        if let last = lastVideo, holdTime > lastVideoTime, videoInput.isReadyForMoreMediaData,
           let held = last.retimed(to: holdTime) {
            videoInput.append(held)
        }
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: endTime)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CaptureError.writerSetup("finish") }
        return endTime
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Settings

    static func videoSettings(_ f: VideoFormat) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoWidthKey: f.width,
            AVVideoHeightKey: f.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch f.codec {
        case .proRes422:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .proRes4444:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        case .h264, .hevc:
            // Screen content needs more bits than camera footage for crisp text.
            let bitsPerPixel = (0.04 + 0.16 * f.quality) * (f.codec == .h264 ? 1.4 : 1)
            let bitrate = Double(f.width * f.height * f.fps) * bitsPerPixel
            settings[AVVideoCodecKey] = f.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: f.fps,
                // Keyframe every second keeps scrubbing in the editor fast.
                AVVideoMaxKeyFrameIntervalKey: f.fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: f.codec == .h264
                    ? AVVideoProfileLevelH264HighAutoLevel
                    : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any]
        }
        return settings
    }

    static func audioSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 192_000 : 128_000,
        ]
    }
}

public enum CaptureError: LocalizedError {
    case permissionDenied
    case targetNotFound
    case writerSetup(String)
    case noFrames
    case deviceUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording permission is required. Enable it in System Settings › Privacy & Security."
        case .targetNotFound: "The selected display or window is no longer available."
        case let .writerSetup(stage): "Couldn't set up the video file (\(stage))."
        case .noFrames: "No frames were captured."
        case .deviceUnavailable: "The device is not available. Connect it with a cable and unlock it."
        }
    }
}

extension CMSampleBuffer {
    /// Copy whose first presentation time is `pts`; all sample timings are shifted by the same offset.
    func retimed(to pts: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr
        else { return nil }
        let offset = pts - timings[0].presentationTimeStamp
        for i in timings.indices {
            timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + offset
            timings[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: self, sampleTimingEntryCount: count,
            sampleTimingArray: &timings, sampleBufferOut: &out
        )
        return status == noErr ? out : nil
    }
}
