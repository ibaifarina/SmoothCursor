import Foundation

/// The editable document. Serialized as `project.json` inside a `.smoothcursor` package.
/// Media files are referenced by package-relative paths and never rewritten by autosave.
public struct Project: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = Project.currentSchemaVersion
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date

    public var recording: RecordingInfo
    public var canvas = CanvasSettings()
    public var cursor = CursorSettings()
    public var motionBlur = MotionBlurSettings()
    public var autoZoom = AutoZoomSettings()
    public var zooms: [ZoomSegment] = []
    /// Set once automatic zooms have been placed, so opening a project never overwrites edits.
    public var autoZoomGenerated = false
    public var mockup = MockupSettings()
    public var cameraClips: [CameraClip] = []
    /// Kept ranges of the source; empty = whole recording.
    public var cuts: [TimeRange] = []
    public var export = ExportSettings()

    public init(id: UUID = UUID(), name: String, recording: RecordingInfo, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.recording = recording
        self.createdAt = createdAt
        self.modifiedAt = createdAt
    }
}

public struct RecordingInfo: Codable, Hashable, Sendable {
    public enum SourceKind: String, Codable, Sendable { case display, window, area, iPhone, simulator, imported }

    public var sourceKind: SourceKind
    /// Package-relative path of the screen video.
    public var videoFile: String
    /// Package-relative path of a separate mic track, if recorded separately.
    public var microphoneFile: String?
    public var cameraFile: String?
    /// Package-relative path of the cursor/input telemetry; nil for imported videos.
    public var telemetryFile: String?
    public var pixelSize: PixelSize
    /// Points-to-pixels factor of the captured display.
    public var displayScale: Double
    public var fps: Double
    public var duration: Seconds
    /// Audio tracks inside `videoFile`, in track order. Nil for imports (inspect the asset instead).
    public var audioTracks: [AudioTrackInfo]?

    public init(
        sourceKind: SourceKind, videoFile: String, microphoneFile: String? = nil, cameraFile: String? = nil,
        telemetryFile: String? = nil, pixelSize: PixelSize, displayScale: Double, fps: Double, duration: Seconds
    ) {
        self.sourceKind = sourceKind; self.videoFile = videoFile; self.microphoneFile = microphoneFile
        self.cameraFile = cameraFile; self.telemetryFile = telemetryFile; self.pixelSize = pixelSize
        self.displayScale = displayScale; self.fps = fps; self.duration = duration
    }
}

public struct AudioTrackInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case system, microphone, device }
    public var kind: Kind
    /// Human-readable source, e.g. the microphone name.
    public var name: String
    public init(kind: Kind, name: String) { self.kind = kind; self.name = name }
}
