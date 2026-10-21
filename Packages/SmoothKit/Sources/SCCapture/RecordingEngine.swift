import CoreGraphics
import Foundation
import SCCore

/// Output of a finished capture, ready to become a project.
public struct CaptureResult: Sendable {
    public var recording: RecordingInfo
    public var telemetry: Telemetry?
    public var framesWritten: Int
    public var framesDropped: Int
}

/// A live capture into a project package. Engines are thread-safe; callers may use them from any actor.
public protocol RecordingEngine: AnyObject, Sendable {
    var clock: RecordingClock { get }
    /// Called (on an arbitrary queue) if capture stops unexpectedly.
    var onFailure: (@Sendable (Error) -> Void)? { get set }

    /// Prepares and starts capture. Writes media into `packageURL/media`.
    func start(settings: RecordingSettings, packageURL: URL) async throws
    func pause()
    func resume()
    func stop() async throws -> CaptureResult
    /// Stops and discards everything written.
    func cancel() async
}

public extension RecordingEngine {
    func pause() { clock.pause() }
    func resume() { clock.resume() }
}

enum PackagePaths {
    static let video = "media/screen.mov"
    static let telemetry = "media/telemetry.sctl"
    static let cursors = "cursors"
}
