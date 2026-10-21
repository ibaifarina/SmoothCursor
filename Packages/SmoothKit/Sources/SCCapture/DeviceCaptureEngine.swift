@preconcurrency import AVFoundation
import CoreMediaIO
import SCCore

/// Records an iPhone/iPad screen over USB, the same way QuickTime does (CoreMediaIO screen capture devices).
public final class DeviceCaptureEngine: NSObject, RecordingEngine, @unchecked Sendable {
    public let clock = RecordingClock()
    public var onFailure: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "smoothcursor.devicecapture", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var writer: CaptureWriter?
    private var settings = RecordingSettings()
    private var packageURL: URL?
    private var deviceName = "iPhone"
    private var pixelSize = PixelSize(width: 0, height: 0)
    private var failed = false

    /// Makes iOS devices connected over USB show up as capture devices. Call early: they appear asynchronously.
    public static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow
        )
    }

    /// Connected iOS devices offering screen capture.
    public static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }

    public func start(settings: RecordingSettings, packageURL: URL) async throws {
        guard case let .iPhone(id) = settings.target, let device = AVCaptureDevice(uniqueID: id) else {
            throw CaptureError.deviceUnavailable
        }
        self.settings = settings
        self.packageURL = packageURL
        deviceName = device.localizedName

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.deviceUnavailable }
        session.addInput(input)

        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        video.alwaysDiscardsLateVideoFrames = false
        video.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(video) else { throw CaptureError.deviceUnavailable }
        session.addOutput(video)

        if settings.captureSystemAudio {
            let audio = AVCaptureAudioDataOutput()
            audio.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(audio) { session.addOutput(audio) }
        }
        session.commitConfiguration()
        self.session = session

        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? CaptureError.deviceUnavailable
            self?.onFailure?(error)
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { session.startRunning(); c.resume() }
        }
    }

    public func stop() async throws -> CaptureResult {
        guard let session else { throw CaptureError.noFrames }
        let end = clock.elapsed
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                session.stopRunning()
                guard let writer = self.writer else { return c.resume(throwing: CaptureError.noFrames) }
                Task {
                    do {
                        let duration = try await writer.finish(end: end)
                        var info = RecordingInfo(
                            sourceKind: .iPhone, videoFile: PackagePaths.video, pixelSize: self.pixelSize,
                            displayScale: 1, fps: Double(self.settings.fps), duration: duration.seconds
                        )
                        info.audioTracks = self.settings.captureSystemAudio
                            ? [AudioTrackInfo(kind: .device, name: self.deviceName)] : []
                        c.resume(returning: CaptureResult(
                            recording: info, telemetry: nil,
                            framesWritten: writer.framesWritten, framesDropped: writer.framesDropped
                        ))
                    } catch {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func cancel() async {
        guard let session else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                session.stopRunning()
                self.writer?.cancel()
                c.resume()
            }
        }
    }

    /// The writer is created from the first frame, since the device's size isn't known until then.
    private func makeWriterIfNeeded(for sample: CMSampleBuffer) {
        guard writer == nil, !failed, let packageURL, let buffer = sample.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(buffer) & ~1, height = CVPixelBufferGetHeight(buffer) & ~1
        pixelSize = PixelSize(width: width, height: height)
        do {
            writer = try CaptureWriter(
                url: packageURL.appending(path: PackagePaths.video),
                video: .init(width: width, height: height, fps: settings.fps, codec: settings.codec, quality: settings.quality),
                audio: settings.captureSystemAudio ? [.device: 2] : [:],
                clock: clock
            )
        } catch {
            failed = true
            onFailure?(error)
        }
    }
}

extension DeviceCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            makeWriterIfNeeded(for: sampleBuffer)
            writer?.appendVideo(sampleBuffer)
        } else {
            writer?.appendAudio(sampleBuffer, slot: .device)
        }
        if let error = writer?.error { onFailure?(error) }
    }
}
