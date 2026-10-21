import Foundation

/// 3D device mockup. Only phones for now.
public struct MockupSettings: Codable, Hashable, Sendable {
    public enum Device: String, Codable, CaseIterable, Sendable { case none, phone }
    public enum Finish: String, Codable, CaseIterable, Sendable { case black, silver, natural, desert, blue }

    public var device: Device = .none
    public var finish: Finish = .black
    /// Lighting environment id (see `MockupEnvironment`).
    public var environment = "studio"
    /// Degrees: rotates the reflections and the shadow around the phone.
    public var lightYaw = 150.0
    /// Degrees: raises or lowers the light.
    public var lightPitch = 0.0
    public var lightStrength = 1.0
    public var shadowOpacity = 0.5
    /// How strongly the screen glass reflects the environment.
    public var screenReflection = 0.5
    public init() {}

    public var isEnabled: Bool { device != .none }
}

public enum MockupEnvironment: String, CaseIterable, Sendable {
    case studio, soft, sunset, neon, white

    public var label: String { rawValue.capitalized }
}

public enum CameraPreset: String, Codable, CaseIterable, Sendable {
    case front, hero, straightOn, orbitLeft, orbitRight, tiltUp, closeUp

    public var label: String {
        switch self {
        case .front: "Front"
        case .hero: "Hero"
        case .straightOn: "Straight On"
        case .orbitLeft: "Orbit Left"
        case .orbitRight: "Orbit Right"
        case .tiltUp: "Tilt Up"
        case .closeUp: "Close Up"
        }
    }
}

/// A camera shot on the Camera track. Transitions between consecutive clips are eased automatically.
public struct CameraClip: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var range: TimeRange
    public var preset: CameraPreset
    /// 0...1 speed of the preset's internal motion (e.g. orbit).
    public var intensity: Double
    public var easing: Easing
    public var transition: Seconds
    /// Close-ups: point on the screen to frame (unit coordinates of the recording). Nil = upper middle.
    public var focus: UnitPoint2D?

    public init(range: TimeRange, preset: CameraPreset, intensity: Double = 0.5, easing: Easing = .default, transition: Seconds = 0.8, focus: UnitPoint2D? = nil) {
        self.range = range; self.preset = preset; self.intensity = intensity; self.easing = easing; self.transition = transition
        self.focus = focus
    }
}
