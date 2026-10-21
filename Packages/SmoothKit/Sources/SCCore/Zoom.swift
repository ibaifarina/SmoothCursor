import Foundation

public struct ZoomSegment: Codable, Hashable, Identifiable, Sendable {
    public enum Focus: Codable, Hashable, Sendable {
        /// Camera follows the smoothed cursor; it only moves when the cursor leaves the dead zone (fraction of view).
        case followCursor(deadZone: Double)
        /// Fixed focus point in source unit space.
        case fixed(UnitPoint2D)
    }

    public enum Origin: String, Codable, Sendable {
        case auto
        case manual
    }

    public var id = UUID()
    public var range: TimeRange
    /// 1 = no zoom. Typical 1.5...3.
    public var scale: Double
    public var focus: Focus
    public var easing: Easing
    public var transitionIn: Seconds
    public var transitionOut: Seconds
    public var followSpring: SpringParams
    public var origin: Origin
    /// Keep the view on the recording when it fits (no background). Off: center on the focus,
    /// showing the padding around the recording, but never past the canvas edge.
    public var staysInRecording: Bool

    public init(
        range: TimeRange,
        scale: Double = 2,
        focus: Focus = .followCursor(deadZone: 0.2),
        easing: Easing = .default,
        transitionIn: Seconds = 0.6,
        transitionOut: Seconds = 0.6,
        followSpring: SpringParams = .smooth,
        origin: Origin = .manual,
        staysInRecording: Bool = true
    ) {
        self.range = range; self.scale = scale; self.focus = focus; self.easing = easing
        self.transitionIn = transitionIn; self.transitionOut = transitionOut
        self.followSpring = followSpring; self.origin = origin; self.staysInRecording = staysInRecording
    }
}

/// Tunables for the automatic zoom placement engine (step 5a).
public struct AutoZoomSettings: Codable, Hashable, Sendable {
    public var enabled = true
    public var defaultScale = 2.0
    /// 0...1: how eagerly zooms are created.
    public var sensitivity = 0.5
    public var minSegmentDuration: Seconds = 1.5
    public var mergeGap: Seconds = 1.0
    /// Default for new zooms (automatic and manual); see `ZoomSegment.staysInRecording`.
    public var staysInRecording = true
    public init() {}
}
