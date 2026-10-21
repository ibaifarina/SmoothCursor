import AppKit
import CoreMedia
import SCCore
@preconcurrency import ScreenCaptureKit

/// Records a display, window or area with ScreenCaptureKit. The cursor is not burned in;
/// it is captured as telemetry and re-rendered by the editor.
public final class ScreenCaptureEngine: NSObject, RecordingEngine, @unchecked Sendable {
    public let clock = RecordingClock()
    public var onFailure: (@Sendable (Error) -> Void)?
    /// Our own HUD/countdown windows, always hidden from the capture.
    public var excludedWindowIDs: [CGWindowID] = []

    private let queue = DispatchQueue(label: "smoothcursor.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var writer: CaptureWriter?
    private var telemetry: InputTelemetryRecorder?
    private var camera: CameraRecorder?
    private var packageURL: URL?
    private var info: RecordingInfo?

    override public init() { super.init() }

    public func start(settings: RecordingSettings, packageURL: URL) async throws {
        guard let target = settings.target else { throw CaptureError.targetNotFound }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.permissionDenied
        }
        let resolved = try resolve(target, settings: settings, content: content)

        let scale = Double(SCShareableContent.info(for: resolved.filter).pointPixelScale)
        let pointSize = resolved.pointSize
        var pixelWidth = pointSize.width * scale * settings.resolutionScale
        var pixelHeight = pointSize.height * scale * settings.resolutionScale
        // Hardware H.264 tops out at 4096 px.
        if settings.codec == .h264, max(pixelWidth, pixelHeight) > 4096 {
            let f = 4096 / max(pixelWidth, pixelHeight)
            pixelWidth *= f; pixelHeight *= f
        }
        let width = Int(pixelWidth) & ~1, height = Int(pixelHeight) & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.pixelFormat = settings.codec.isProRes ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = false
        config.showMouseClicks = false
        config.queueDepth = 8
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        if let sourceRect = resolved.sourceRect { config.sourceRect = sourceRect }
        config.capturesAudio = settings.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if let mic = settings.microphoneID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = mic
        }

        var audio: [CaptureWriter.AudioSlot: Int] = [:]
        var audioTracks: [AudioTrackInfo] = []
        if settings.captureSystemAudio {
            audio[.system] = 2
            audioTracks.append(AudioTrackInfo(kind: .system, name: "System Audio"))
        }
        if let mic = settings.microphoneID {
            audio[.microphone] = 1
            audioTracks.append(AudioTrackInfo(kind: .microphone, name: AVCaptureDevice(uniqueID: mic)?.localizedName ?? "Microphone"))
        }

        let videoURL = packageURL.appending(path: PackagePaths.video)
        let writer = try CaptureWriter(
            url: videoURL,
            video: .init(width: width, height: height, fps: settings.fps, codec: settings.codec, quality: settings.quality),
            audio: audio, clock: clock
        )
        let stream = SCStream(filter: resolved.filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.captureSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if settings.microphoneID != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }

        let telemetry = InputTelemetryRecorder(
            clock: clock, target: resolved.telemetryTarget, targetSize: pointSize,
            displayScale: scale, packageURL: packageURL
        )

        self.writer = writer
        self.stream = stream
        self.telemetry = telemetry
        self.packageURL = packageURL
        info = RecordingInfo(
            sourceKind: resolved.sourceKind, videoFile: PackagePaths.video,
            telemetryFile: PackagePaths.telemetry, pixelSize: PixelSize(width: width, height: height),
            displayScale: scale * settings.resolutionScale, fps: Double(settings.fps), duration: 0
        )
        info?.audioTracks = audioTracks

        if let cameraID = settings.cameraID {
            camera = try? CameraRecorder(deviceID: cameraID, packageURL: packageURL, clock: clock)
            // Wake the webcam first: its frames are dropped until the screen starts the clock.
            await camera?.start()
        }
        telemetry.start()
        do {
            try await stream.startCapture()
        } catch {
            _ = telemetry.stop()
            camera?.cancel()
            writer.cancel()
            throw error
        }
    }

    public func stop() async throws -> CaptureResult {
        guard let stream, let writer, let packageURL, var info else { throw CaptureError.noFrames }
        let end = clock.elapsed
        try? await stream.stopCapture()
        let telemetryData = telemetry?.stop()
        let duration = try await onQueue { try await writer.finish(end: end) }
        self.stream = nil
        if let camera, await camera.stop(end: end) { info.cameraFile = CameraRecorder.file }
        camera = nil

        info.duration = duration.seconds
        if let telemetryData {
            try telemetryData.encoded().write(to: packageURL.appending(path: PackagePaths.telemetry), options: .atomic)
        } else {
            info.telemetryFile = nil
        }
        return CaptureResult(
            recording: info, telemetry: telemetryData,
            framesWritten: writer.framesWritten, framesDropped: writer.framesDropped
        )
    }

    public func cancel() async {
        camera?.cancel()
        camera = nil
        try? await stream?.stopCapture()
        _ = telemetry?.stop()
        if let writer { await onQueue { writer.cancel() } }
        stream = nil
    }

    /// Runs `work` after all in-flight sample callbacks on the capture queue.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async rethrows -> T {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
        return try await work()
    }

    // MARK: Target resolution

    private struct Resolved {
        var filter: SCContentFilter
        var pointSize: CGSize
        var sourceRect: CGRect?
        var telemetryTarget: InputTelemetryRecorder.Target
        var sourceKind: RecordingInfo.SourceKind
    }

    private func resolve(_ target: CaptureTarget, settings: RecordingSettings, content: SCShareableContent) throws -> Resolved {
        func displayFilter(_ display: SCDisplay) -> SCContentFilter {
            let hud = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
            if settings.excludeOwnWindows {
                let me = content.applications.filter { $0.processID == getpid() }
                return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            }
            return SCContentFilter(display: display, excludingWindows: hud)
        }

        switch target {
        case let .display(id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.targetNotFound }
            let bounds = CGDisplayBounds(id)
            return Resolved(
                filter: displayFilter(display), pointSize: bounds.size, sourceRect: nil,
                telemetryTarget: .rect(bounds), sourceKind: .display
            )
        case let .area(id, x, y, w, h):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.targetNotFound }
            let bounds = CGDisplayBounds(id)
            let local = CGRect(x: x, y: y, width: w, height: h).integral.intersection(CGRect(origin: .zero, size: bounds.size))
            return Resolved(
                filter: displayFilter(display), pointSize: local.size, sourceRect: local,
                telemetryTarget: .rect(local.offsetBy(dx: bounds.minX, dy: bounds.minY)), sourceKind: .area
            )
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.targetNotFound }
            let isSimulator = window.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
            return Resolved(
                filter: SCContentFilter(desktopIndependentWindow: window), pointSize: window.frame.size, sourceRect: nil,
                telemetryTarget: .window(id, initial: window.frame), sourceKind: isSimulator ? .simulator : .window
            )
        case .iPhone:
            throw CaptureError.targetNotFound
        }
    }
}

extension ScreenCaptureEngine: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete
            else { return }
            writer.appendVideo(sampleBuffer)
        case .audio:
            writer.appendAudio(sampleBuffer, slot: .system)
        case .microphone:
            writer.appendAudio(sampleBuffer, slot: .microphone)
        @unknown default:
            break
        }
        if let error = writer.error { onFailure?(error) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }
}

extension VideoCodec {
    var isProRes: Bool { self == .proRes422 || self == .proRes4444 }
}
