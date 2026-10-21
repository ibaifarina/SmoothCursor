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
    /// Short side of the output in pixels (1080 → 1920×1080 landscape, 1080×1920 vertical).
    public var height = 1080
    public var fps = 60
    public var quality = 0.8
    public var includeAudio = true
    public init() {}

    /// Output pixel size for a canvas aspect (width ÷ height); even numbers for the encoders.
    public func outputSize(aspect: Double) -> PixelSize {
        let short = Double(format == .gif ? min(height, 720) : height)
        let w = aspect >= 1 ? short * aspect : short
        let h = aspect >= 1 ? short : short / max(aspect, 0.01)
        return PixelSize(width: Int(w.rounded()) & ~1, height: Int(h.rounded()) & ~1)
    }

    /// GIFs are capped at 30 fps (players ignore faster frame delays anyway).
    public var effectiveFPS: Int { format == .gif ? min(fps, 30) : fps }

    /// Rough encoded size, for the export panel.
    public func estimatedBytes(aspect: Double, duration: Seconds) -> Double {
        let size = outputSize(aspect: aspect)
        let pixels = Double(size.width * size.height)
        let bitsPerSecond: Double = switch (format, codec) {
        case (.gif, _): pixels * Double(effectiveFPS) * 0.9
        case (_, .proRes422): pixels * Double(fps) * 4.5
        case (_, .proRes4444): pixels * Double(fps) * 7
        case (_, .hevc): pixels * Double(fps) * (0.025 + 0.1 * quality)
        default: pixels * Double(fps) * (0.035 + 0.14 * quality)
        }
        return (bitsPerSecond + (includeAudio ? 192_000 : 0)) * duration / 8
    }
}
