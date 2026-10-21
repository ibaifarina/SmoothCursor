import Foundation

public enum AspectRatio: Codable, Hashable, Sendable {
    /// Match the (cropped) source.
    case source
    case wide16x9
    case vertical9x16
    case square
    case portrait4x5
    case classic4x3
    case custom(width: Int, height: Int)

    public static let presets: [AspectRatio] = [.source, .wide16x9, .vertical9x16, .square, .portrait4x5, .classic4x3]

    public func ratio(source: Double) -> Double {
        switch self {
        case .source: source
        case .wide16x9: 16.0 / 9.0
        case .vertical9x16: 9.0 / 16.0
        case .square: 1
        case .portrait4x5: 4.0 / 5.0
        case .classic4x3: 4.0 / 3.0
        case let .custom(w, h): h == 0 ? 1 : Double(w) / Double(h)
        }
    }

    public var label: String {
        switch self {
        case .source: "Auto"
        case .wide16x9: "Wide 16:9"
        case .vertical9x16: "Vertical 9:16"
        case .square: "Square 1:1"
        case .portrait4x5: "Portrait 4:5"
        case .classic4x3: "Classic 4:3"
        case let .custom(w, h): "\(w):\(h)"
        }
    }
}

public struct GradientStop: Codable, Hashable, Sendable {
    public var location: Double
    public var color: RGBAColor
    public init(_ location: Double, _ color: RGBAColor) { self.location = location; self.color = color }
}

public struct GradientSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case linear, radial, angular, mesh }

    public var kind: Kind
    public var stops: [GradientStop]
    /// Degrees, for linear/angular.
    public var angle: Double
    /// Center for radial/angular.
    public var center: UnitPoint2D
    /// 3x3 control colors for mesh gradients, row-major. Empty for other kinds.
    public var meshColors: [RGBAColor]

    public init(kind: Kind, stops: [GradientStop], angle: Double = 135, center: UnitPoint2D = .center, meshColors: [RGBAColor] = []) {
        self.kind = kind; self.stops = stops; self.angle = angle; self.center = center; self.meshColors = meshColors
    }

    public static let sunset = GradientSpec(kind: .linear, stops: [
        GradientStop(0, RGBAColor(hex: 0xFF7A18)), GradientStop(1, RGBAColor(hex: 0xAF002D)),
    ])
}

public enum Background: Codable, Hashable, Sendable {
    case color(RGBAColor)
    case gradient(GradientSpec)
    /// Image file stored inside the project package (relative path) or a bundled wallpaper id.
    case image(ImageBackground)

    public static let `default` = Background.gradient(.sunset)
}

public struct ImageBackground: Codable, Hashable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        case bundled(id: String)
        case projectFile(relativePath: String)
    }
    public var source: Source
    public var blur: Double
    public init(source: Source, blur: Double = 0) { self.source = source; self.blur = blur }
}

public struct ShadowSettings: Codable, Hashable, Sendable {
    public var enabled = true
    public var opacity = 0.45
    /// Radius in points of the output canvas at 1080p reference height.
    public var radius = 40.0
    public var offsetY = 16.0
    public init() {}
}

public struct CanvasSettings: Codable, Hashable, Sendable {
    public var aspect: AspectRatio = .source
    public var background: Background = .default
    /// Fraction of the shorter canvas side left as margin around the video.
    public var padding = 0.08
    public var cornerRadius = 14.0
    public var shadow = ShadowSettings()
    /// Crop applied to the source frame before it is placed on the canvas.
    public var crop: UnitRect = .full
    /// Film grain / noise on the background, 0...1.
    public var backgroundNoise = 0.0
    public init() {}
}
