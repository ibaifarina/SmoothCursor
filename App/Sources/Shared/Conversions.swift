import SCCore
import SwiftUI

extension RGBAColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }
}

extension Background {
    /// Lightweight SwiftUI approximation used until the Metal preview lands (step 3).
    @ViewBuilder var swiftUIView: some View {
        switch self {
        case let .color(c):
            c.color
        case let .gradient(g):
            let gradient = Gradient(stops: g.stops.map { .init(color: $0.color.color, location: $0.location) })
            let center = UnitPoint(x: g.center.x, y: g.center.y)
            switch g.kind {
            case .linear:
                LinearGradient(gradient: gradient, startPoint: .init(angle: g.angle, end: false), endPoint: .init(angle: g.angle, end: true))
            case .radial:
                RadialGradient(gradient: gradient, center: center, startRadius: 0, endRadius: 800)
            case .angular:
                AngularGradient(gradient: gradient, center: center, angle: .degrees(g.angle))
            case .mesh:
                if g.meshColors.count == 9 {
                    MeshGradient(width: 3, height: 3, points: [
                        [0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.5, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1],
                    ], colors: g.meshColors.map(\.color))
                } else {
                    LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)
                }
            }
        case .image:
            Color.gray
        }
    }
}

private extension UnitPoint {
    /// Start/end points of a linear gradient at `angle` degrees (0 = left→right, clockwise).
    init(angle: Double, end: Bool) {
        let rad = angle * .pi / 180
        let dx = cos(rad) / 2, dy = sin(rad) / 2
        self = end ? UnitPoint(x: 0.5 + dx, y: 0.5 + dy) : UnitPoint(x: 0.5 - dx, y: 0.5 - dy)
    }
}

extension Seconds {
    var timecode: String {
        let total = max(0, self)
        let m = Int(total) / 60, s = Int(total) % 60, cs = Int((total - floor(total)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}
