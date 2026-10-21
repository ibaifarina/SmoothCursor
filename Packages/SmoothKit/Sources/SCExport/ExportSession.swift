@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Metal
import SCCore
import SCProject
import SCRender
import Synchronization
import UniformTypeIdentifiers

/// Everything needed to export a project. Tracks come from the editor (same ones the preview uses).
public struct ExportRequest: Sendable {
    public var project: Project
    public var packageURL: URL
    public var destination: URL
    public var cursor: CursorTrack?
    public var camera: CameraTrack?

    public init(project: Project, packageURL: URL, destination: URL, cursor: CursorTrack?, camera: CameraTrack?) {
        self.project = project; self.packageURL = packageURL; self.destination = destination
        self.cursor = cursor; self.camera = camera
    }
}

public struct ExportProgress: Sendable {
    public var framesRendered: Int
    public var totalFrames: Int
    public var fraction: Double { totalFrames > 0 ? Double(framesRendered) / Double(totalFrames) : 0 }
}

public enum ExportError: LocalizedError {
    case noVideo, noMetal, writer(String), cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideo: "The recording has no video track."
        case .noMetal: "Metal is not available."
        case let .writer(message): "Couldn't write the video: \(message)"
        case .cancelled: "Export cancelled."
        }
    }
}

/// Renders a project to a movie (H.264 / HEVC / ProRes, with audio and click sounds) or a GIF.
///
/// Cuts are applied by building an `AVMutableComposition` of the kept ranges, so both readers
/// deliver media already on the output timeline. Each output frame maps back to source time for
/// the zoom camera and cursor, is drawn by the same `Compositor` as the preview (export-quality
/// motion blur) straight into the encoder's IOSurface, and is hardware encoded.
public final class ExportSession: @unchecked Sendable {
    public let request: ExportRequest
    private let cancelled = Atomic<Bool>(false)

    public init(request: ExportRequest) {
        self.request = request
    }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    private var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    public func run(progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        try? FileManager.default.removeItem(at: request.destination)
        do {
            if request.project.export.format == .gif {
                try await runGIF(progress: progress)
            } else {
                try await runMovie(progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: request.destination)
            throw isCancelled ? ExportError.cancelled : error
        }
    }

    // MARK: Shared setup

    private struct Media {
        let composition: AVMutableComposition
        let video: AVMutableCompositionTrack
        let audio: [AVMutableCompositionTrack]
        let kept: [TimeRange]
        let duration: Seconds
    }

    private func buildComposition(includeAudio: Bool) async throws -> Media {
        let project = request.project
        let asset = AVURLAsset(url: ProjectPackage.mediaURL(project.recording.videoFile, in: request.packageURL))
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let sourceAudio = includeAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        let assetDuration = try await asset.load(.duration).seconds

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.noVideo
        }
        var audio: [(AVMutableCompositionTrack, AVAssetTrack, CMTimeRange)] = []
        for track in sourceAudio {
            if let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                audio.append((t, track, try await track.load(.timeRange)))
            }
        }
        let videoRange = try await sourceVideo.load(.timeRange)

        let kept = Cuts.kept(project).compactMap { r -> TimeRange? in
            let clipped = TimeRange(start: max(r.start, 0), end: min(r.end, assetDuration))
            return clipped.duration > 0.001 ? clipped : nil
        }
        var at = CMTime.zero
        for r in kept {
            let range = CMTimeRange(start: CMTime(seconds: r.start, preferredTimescale: 60_000),
                                    end: CMTime(seconds: r.end, preferredTimescale: 60_000))
            try video.insertTimeRange(range.intersection(videoRange), of: sourceVideo, at: at)
            for (track, source, sourceRange) in audio {
                let part = range.intersection(sourceRange)
                if part.duration > .zero { try track.insertTimeRange(part, of: source, at: at + (part.start - range.start)) }
            }
            at = at + range.duration
        }
        return Media(composition: composition, video: video, audio: audio.map(\.0), kept: kept, duration: at.seconds)
    }

    /// Frame layout and motion blur for output time `t`.
    private func frame(at t: Seconds, kept: [TimeRange], size: CGSize, fps: Int) -> (FrameLayout, MotionBlurFrame?) {
        let project = request.project
        let source = Cuts.sourceTime(forOutput: t, in: kept)
        let layout = FrameLayout.make(project: project, time: source, outputSize: size, cursor: request.cursor, camera: request.camera)
        let motion = FrameLayout.motionBlur(
            project: project, time: source, outputSize: size, cursor: request.cursor, camera: request.camera,
            frameDuration: 1 / Double(fps), quality: .export
        )
        return (layout, motion)
    }

    private func makeCompositor(_ context: MetalContext) throws -> Compositor {
        let compositor = try Compositor(context: context)
        let package = request.packageURL
        compositor.imageResolver = { source in
            if case let .projectFile(path) = source { return package.appending(path: path) }
            return nil
        }
        return compositor
    }

    // MARK: Movie

    private func runMovie(progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        guard let context = MetalContext.shared else { throw ExportError.noMetal }
        let project = request.project
        let settings = project.export
        let media = try await buildComposition(includeAudio: settings.includeAudio)
        let pixelSize = settings.outputSize(aspect: FrameLayout.outputAspect(for: project))
        let size = CGSize(width: pixelSize.width, height: pixelSize.height)
        let fps = settings.fps
        let total = max(Int((media.duration * Double(fps)).rounded(.up)), 1)
        let compositor = try makeCompositor(context)

        // Writer
        let proRes = settings.codec == .proRes422 || settings.codec == .proRes4444
        let writer = try AVAssetWriter(outputURL: request.destination, fileType: proRes || settings.format == .mov ? .mov : .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(settings, size: pixelSize))
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelSize.width,
            kCVPixelBufferHeightKey as String: pixelSize.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(videoInput)

        let clicks = clickTimes(kept: media.kept)
        let audioSource: AudioSource? = if !media.audio.isEmpty {
            try AudioSource(tracks: media.audio, composition: media.composition, clicks: clicks)
        } else if !clicks.isEmpty {
            AudioSource(synthesizing: media.duration, clicks: clicks)
        } else {
            nil
        }
        var audioInput: AVAssetWriterInput?
        if audioSource != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        // Video reader
        let reader = try AVAssetReader(asset: media.composition)
        let videoOutput = AVAssetReaderTrackOutput(track: media.video, outputSettings: rendererPixelBufferAttributes)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        guard reader.startReading() else { throw reader.error ?? ExportError.noVideo }
        try audioSource?.start()

        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let frames = FrameStream(output: videoOutput)
        let videoQueue = DispatchQueue(label: "smoothcursor.export.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "smoothcursor.export.audio", qos: .userInitiated)
        nonisolated(unsafe) var index = 0
        nonisolated(unsafe) var failure: Error?

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    videoInput.requestMediaDataWhenReady(on: videoQueue) {
                        while videoInput.isReadyForMoreMediaData {
                            if self.isCancelled || index >= total || failure != nil {
                                videoInput.markAsFinished()
                                done.resume()
                                return
                            }
                            let t = Double(index) / Double(fps)
                            guard let pool = adaptor.pixelBufferPool else { continue }
                            var buffer: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                            guard let buffer, let target = context.makeTexture(from: buffer, renderTarget: true),
                                  let commandBuffer = context.queue.makeCommandBuffer() else {
                                failure = ExportError.writer("pixel buffer")
                                continue
                            }
                            let source = frames.frame(at: t)
                            let sourceTexture = source.flatMap { context.makeTexture(from: $0) }
                            let (layout, motion) = self.frame(at: t, kept: media.kept, size: size, fps: fps)
                            compositor.encode(
                                layout: layout, source: sourceTexture?.texture, sourceChanged: frames.changed,
                                into: target.texture, commandBuffer: commandBuffer, motion: motion
                            )
                            commandBuffer.commit()
                            commandBuffer.waitUntilCompleted()
                            withExtendedLifetime((sourceTexture, target)) {}
                            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) {
                                failure = writer.error ?? ExportError.writer("append")
                            }
                            index += 1
                            if index % 4 == 0 || index == total { progress(ExportProgress(framesRendered: index, totalFrames: total)) }
                        }
                    }
                }
            }
            if let audioInput, let audioSource {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        audioInput.requestMediaDataWhenReady(on: audioQueue) {
                            while audioInput.isReadyForMoreMediaData {
                                if self.isCancelled { audioInput.markAsFinished(); done.resume(); return }
                                guard let sample = audioSource.next() else {
                                    audioInput.markAsFinished()
                                    done.resume()
                                    return
                                }
                                audioInput.append(sample)
                            }
                        }
                    }
                }
            }
        }

        reader.cancelReading()
        audioSource?.stop()
        if isCancelled { writer.cancelWriting(); throw ExportError.cancelled }
        if let failure { writer.cancelWriting(); throw failure }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.writer(writer.error?.localizedDescription ?? "finish") }
    }

    static func videoSettings(_ s: ExportSettings, size: PixelSize) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch s.codec {
        case .proRes422: settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .proRes4444: settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        case .h264, .hevc:
            let bpp = s.codec == .hevc ? 0.025 + 0.1 * s.quality : 0.035 + 0.14 * s.quality
            settings[AVVideoCodecKey] = s.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(Double(size.width * size.height * s.fps) * bpp),
                AVVideoExpectedSourceFrameRateKey: s.fps,
                AVVideoMaxKeyFrameIntervalKey: s.fps * 2,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: s.codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any]
        }
        return settings
    }

    /// Click times on the output timeline (clicks inside cut regions are dropped).
    private func clickTimes(kept: [TimeRange]) -> [Seconds] {
        guard request.project.cursor.clickSound, let cursor = request.cursor else { return [] }
        return cursor.clicks.compactMap { Cuts.outputTime(forSource: $0.time, in: kept) }
    }

    // MARK: GIF

    private func runGIF(progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        guard let context = MetalContext.shared else { throw ExportError.noMetal }
        let project = request.project
        let media = try await buildComposition(includeAudio: false)
        let pixelSize = project.export.outputSize(aspect: FrameLayout.outputAspect(for: project))
        let size = CGSize(width: pixelSize.width, height: pixelSize.height)
        // GIF delays are whole hundredths of a second: render on that grid so timing stays exact.
        let delay = max((100 / Double(project.export.effectiveFPS)).rounded(), 2) / 100
        let fps = Int((1 / delay).rounded())
        let total = max(Int((media.duration / delay).rounded(.up)), 1)
        let renderer = try OfflineRenderer(context: context)
        let package = request.packageURL
        renderer.compositor.imageResolver = { source in
            if case let .projectFile(path) = source { return package.appending(path: path) }
            return nil
        }

        let reader = try AVAssetReader(asset: media.composition)
        let output = AVAssetReaderTrackOutput(track: media.video, outputSettings: rendererPixelBufferAttributes)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExportError.noVideo }
        defer { reader.cancelReading() }

        guard let destination = CGImageDestinationCreateWithURL(request.destination as CFURL, UTType.gif.identifier as CFString, total, nil) else {
            throw ExportError.writer("gif")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        let frames = FrameStream(output: output)
        for index in 0..<total {
            if isCancelled { throw ExportError.cancelled }
            let t = Double(index) * delay
            let (layout, motion) = frame(at: t, kept: media.kept, size: size, fps: fps)
            let image = try renderer.render(layout: layout, source: frames.frame(at: t), motion: motion)
            CGImageDestinationAddImage(destination, image, frameProperties)
            if index % 3 == 0 || index == total - 1 { progress(ExportProgress(framesRendered: index + 1, totalFrames: total)) }
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.writer("gif finalize") }
    }
}

/// Sequential decoded frames with "the frame on screen at time t" lookup.
private final class FrameStream: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private var lastReturned: CMSampleBuffer?
    /// Whether the last `frame(at:)` returned a different frame than the call before (mips need rebuilding).
    private(set) var changed = true

    init(output: AVAssetReaderOutput) {
        self.output = output
        current = output.copyNextSampleBuffer()
        next = output.copyNextSampleBuffer()
    }

    func frame(at t: Seconds) -> CVPixelBuffer? {
        while let n = next, n.presentationTimeStamp.seconds <= t + 1e-6 {
            current = n
            next = output.copyNextSampleBuffer()
        }
        changed = current !== lastReturned
        lastReturned = current
        return current?.imageBuffer
    }
}

import VideoToolbox
