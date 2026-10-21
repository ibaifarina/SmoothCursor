@preconcurrency import AVFoundation
import SCCore

/// Records the webcam alongside the screen, on the screen's clock, into `media/camera.mov`.
final class CameraRecorder: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let file = "media/camera.mov"

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "smoothcursor.camera", qos: .userInitiated)
    private var writer: CaptureWriter?
    private let clock: RecordingClock
    private let url: URL

    init(deviceID: String, packageURL: URL, clock: RecordingClock) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw CaptureError.deviceUnavailable }
        self.clock = clock
        url = packageURL.appending(path: Self.file)
        super.init()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.deviceUnavailable }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.deviceUnavailable }
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        queue.async { self.session.startRunning() }
    }

    /// Stops and finishes the file. Returns false if nothing was recorded.
    func stop(end: CMTime) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async {
                self.session.stopRunning()
                guard let writer = self.writer else { return c.resume(returning: false) }
                Task {
                    let ok = (try? await writer.finish(end: end)) != nil
                    c.resume(returning: ok)
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.session.stopRunning()
            self.writer?.cancel()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if writer == nil, let buffer = sampleBuffer.imageBuffer {
            let w = CVPixelBufferGetWidth(buffer) & ~1, h = CVPixelBufferGetHeight(buffer) & ~1
            writer = try? CaptureWriter(url: url, video: .init(width: w, height: h, fps: 30, codec: .hevc, quality: 0.6), audio: [:], clock: clock)
            writer?.startsClock = false
        }
        writer?.appendVideo(sampleBuffer)
    }
}
