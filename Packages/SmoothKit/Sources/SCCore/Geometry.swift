import Foundation

/// Time in seconds on the source recording's timeline.
public typealias Seconds = Double

public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    public static let white = RGBAColor(1, 1, 1)
    public static let black = RGBAColor(0, 0, 0)
}

/// Point in unit space (0...1) relative to the recorded frame, origin top-left.
public struct UnitPoint2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let center = UnitPoint2D(x: 0.5, y: 0.5)
}

/// Rect in unit space (0...1) relative to the recorded frame, origin top-left.
public struct UnitRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
}

public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var aspect: Double { height == 0 ? 1 : Double(width) / Double(height) }
}

/// Half-open time range on the source timeline.
public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Seconds
    public var end: Seconds
    public init(start: Seconds, end: Seconds) { self.start = start; self.end = end }
    public var duration: Seconds { end - start }
    public func contains(_ t: Seconds) -> Bool { t >= start && t < end }
}
