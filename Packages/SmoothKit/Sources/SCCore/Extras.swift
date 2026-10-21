import Foundation

/// Per-track audio levels (track order = `RecordingInfo.audioTracks` / the asset's audio tracks).
public struct AudioSettings: Codable, Hashable, Sendable {
    public var volumes: [Double] = []
    public var muted: [Bool] = []
    public var master = 1.0
    public init() {}

    public func volume(track i: Int) -> Double {
        let muted = muted.indices.contains(i) && muted[i]
        return muted ? 0 : (volumes.indices.contains(i) ? volumes[i] : 1) * master
    }
}

public enum OverlayPosition: String, Codable, CaseIterable, Sendable { case top, bottom }

public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

/// Pills showing the shortcuts (and optionally the typing) during the recording.
public struct KeystrokeSettings: Codable, Hashable, Sendable {
    public var enabled = false
    /// Off by default: typing can include things that shouldn't be in a video.
    public var showTyping = false
    public var position: OverlayPosition = .bottom
    /// Multiplier on the default size.
    public var size = 1.0
    public var lightStyle = false
    public init() {}
}

public struct CaptionSegment: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var range: TimeRange
    public var text: String
    public init(range: TimeRange, text: String) { self.range = range; self.text = text }
}

public struct CaptionSettings: Codable, Hashable, Sendable {
    public var enabled = true
    public var position: OverlayPosition = .bottom
    public var size = 1.0
    /// Text on a dark box (true) or bare white text with a shadow.
    public var boxed = true
    /// Language used for the last transcription (BCP-47).
    public var language: String?
    public init() {}
}

/// Hides part of the recording (passwords, emails…).
public struct RedactRegion: Codable, Hashable, Identifiable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable { case blur, pixelate }
    public var id = UUID()
    public var range: TimeRange
    /// Source unit coordinates.
    public var rect: UnitRect
    public var style: Style = .blur
    public init(range: TimeRange, rect: UnitRect, style: Style = .blur) { self.range = range; self.rect = rect; self.style = style }
}

public struct WebcamSettings: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case circle, rounded }
    public var visible = true
    public var shape: Shape = .circle
    /// Fraction of the output's short side.
    public var size = 0.24
    public var corner: Corner = .bottomRight
    public var mirror = true
    /// Shrinks while zoomed in so it doesn't cover the action.
    public var shrinkDuringZoom = true
    public init() {}
}

/// A saved look applied to projects: everything about appearance, nothing about content.
public struct StylePreset: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var canvas: CanvasSettings
    public var cursor: CursorSettings
    public var motionBlur: MotionBlurSettings
    public var autoZoom: AutoZoomSettings
    public var keystrokes: KeystrokeSettings
    public var captions: CaptionSettings
    public var webcam: WebcamSettings
    public var export: ExportSettings

    public init(name: String, from p: Project) {
        self.name = name
        canvas = p.canvas
        canvas.crop = .full // crops belong to a recording, not a style
        cursor = p.cursor
        motionBlur = p.motionBlur
        autoZoom = p.autoZoom
        keystrokes = p.keystrokes
        captions = p.captions
        webcam = p.webcam
        export = p.export
    }

    public func apply(to p: inout Project) {
        let crop = p.canvas.crop
        p.canvas = canvas
        p.canvas.crop = crop
        p.cursor = cursor
        p.motionBlur = motionBlur
        p.autoZoom = autoZoom
        p.keystrokes = keystrokes
        let language = p.captions.language
        p.captions = captions
        p.captions.language = language
        p.webcam = webcam
        p.export = export
    }
}
