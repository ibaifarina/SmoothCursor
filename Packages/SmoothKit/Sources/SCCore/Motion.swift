import Foundation

/// Physical spring, used for cursor smoothing, follow-cursor and zoom transitions.
public struct SpringParams: Codable, Hashable, Sendable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double

    public init(stiffness: Double, damping: Double, mass: Double = 1) {
        self.stiffness = stiffness; self.damping = damping; self.mass = mass
    }

    public static let smooth = SpringParams(stiffness: 170, damping: 26)
    public static let snappy = SpringParams(stiffness: 320, damping: 32)
    public static let gentle = SpringParams(stiffness: 90, damping: 20)
    public static let bouncy = SpringParams(stiffness: 220, damping: 14)
}

public enum Easing: Codable, Hashable, Sendable {
    case linear
    case easeInOut
    case easeOut
    case easeIn
    /// CSS-style cubic bezier control points.
    case cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double)
    case spring(SpringParams)

    public static let `default` = Easing.cubicBezier(x1: 0.65, y1: 0, x2: 0.35, y2: 1)
}

public struct MotionBlurSettings: Codable, Hashable, Sendable {
    public var enabled = true
    /// 0...1, scales blur length. 0.5 ≈ 180° shutter.
    public var amount = 0.5
    public var applyToCursor = true
    public var applyToCamera = true
    public init() {}
}
