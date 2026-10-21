import Foundation

public struct CursorSettings: Codable, Hashable, Sendable {
    public enum SpriteSource: Codable, Hashable, Sendable {
        /// Sprites captured from macOS during recording (arrow, I-beam, hand…).
        case system
        /// A user-imported pack stored in Application Support, by id.
        case customPack(id: String)
    }

    public enum ClickEffect: String, Codable, CaseIterable, Sendable { case none, ripple, pulse, press }

    public var visible = true
    /// Multiplier on the native cursor size.
    public var scale = 1.5
    public var sprite: SpriteSource = .system
    public var smoothing = SpringParams.smooth
    /// 0 disables smoothing (raw positions).
    public var smoothingAmount = 0.7
    public var hideWhenIdle = true
    public var idleDelay: Seconds = 2.5
    public var clickEffect: ClickEffect = .ripple
    public var clickEffectColor = RGBAColor(1, 1, 1, 0.6)
    public var clickSound = false
    /// Click sound level, 0...2 (1 = as recorded).
    public var clickVolume = 1.0
    /// Rotate the arrow slightly in the direction of motion.
    public var tiltWithMotion = true
    public init() {}
}
