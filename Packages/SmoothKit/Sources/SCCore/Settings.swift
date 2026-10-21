import Foundation

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc, proRes422, proRes4444

    public var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422: "ProRes 422"
        case .proRes4444: "ProRes 4444"
        }
    }
}

public enum CaptureTarget: Codable, Hashable, Sendable {
    case display(id: UInt32)
    case window(id: UInt32)
    /// Area on a display, in display points, origin top-left.
    case area(displayID: UInt32, x: Double, y: Double, width: Double, height: Double)
    case iPhone(deviceID: String)
}

public struct RecordingSettings: Codable, Hashable, Sendable {
    public var target: CaptureTarget?
    public var fps = 60
    /// 1 = native pixel resolution (Retina), 0.5 = half.
    public var resolutionScale = 1.0
    public var codec: VideoCodec = .hevc
    /// 0...1 maps to bitrate for HEVC/H.264; ignored for ProRes.
    public var quality = 0.85
    public var captureSystemAudio = true
    /// `nil` = no microphone.
    public var microphoneID: String?
    public var cameraID: String?
    public var countdown = 3
    public var excludeOwnWindows = true
    public init() {}
}

public struct ExportSettings: Codable, Hashable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable { case mp4, mov, gif }

    public var format: Format = .mp4
    public var codec: VideoCodec = .h264
    /// Output height in pixels; width is derived from the canvas aspect.
    public var height = 1080
    public var fps = 60
    public var quality = 0.8
    public init() {}
}
