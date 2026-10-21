import Foundation

/// 3D device mockup (step 9). Only phones for now.
public struct MockupSettings: Codable, Hashable, Sendable {
    public enum Device: String, Codable, CaseIterable, Sendable { case none, phone }
    public enum Finish: String, Codable, CaseIterable, Sendable { case black, silver, natural, desert, blue }

    public var device: Device = .none
    public var finish: Finish = .black
    public var environment = "studio"
    public var lightYaw = 150.0
    public var lightPitch = 0.0
    public var lightStrength = 1.0
    public var shadowOpacity = 0.5
    public init() {}
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

    public init(range: TimeRange, preset: CameraPreset, intensity: Double = 0.5, easing: Easing = .default, transition: Seconds = 0.8) {
        self.range = range; self.preset = preset; self.intensity = intensity; self.easing = easing; self.transition = transition
    }
}
