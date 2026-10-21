import CoreGraphics
import Foundation

/// Crop rectangle math in source unit space (0...1 on both axes).
public enum CropGeometry {
    public enum Handle: Hashable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

        public static let resizers: [Handle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

        public var isEdge: Bool { [.top, .right, .bottom, .left].contains(self) }

        public func anchor(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .top: CGPoint(x: r.midX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .right: CGPoint(x: r.maxX, y: r.midY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            case .bottom: CGPoint(x: r.midX, y: r.maxY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            case .left: CGPoint(x: r.minX, y: r.midY)
            case .move: CGPoint(x: r.midX, y: r.midY)
            }
        }
    }

    public static let minSize = 0.05

    /// `unitRatio` is the locked width ÷ height in unit space (pixel ratio ÷ source aspect).
    public static func apply(_ handle: Handle, to start: UnitRect, delta: CGSize, unitRatio: Double?) -> UnitRect {
        var minX = start.x, minY = start.y, maxX = start.x + start.width, maxY = start.y + start.height
        let dx = delta.width, dy = delta.height

        if handle == .move {
            let x = min(max(start.x + dx, 0), 1 - start.width)
            let y = min(max(start.y + dy, 0), 1 - start.height)
            return UnitRect(x: x, y: y, width: start.width, height: start.height)
        }
        if [.topLeft, .left, .bottomLeft].contains(handle) { minX = min(max(minX + dx, 0), maxX - minSize) }
        if [.topRight, .right, .bottomRight].contains(handle) { maxX = max(min(maxX + dx, 1), minX + minSize) }
        if [.topLeft, .top, .topRight].contains(handle) { minY = min(max(minY + dy, 0), maxY - minSize) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { maxY = max(min(maxY + dy, 1), minY + minSize) }

        guard let ratio = unitRatio else {
            return UnitRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        // Aspect lock: derive the other dimension, anchored on the opposite side (centered for edges).
        var w = maxX - minX, h = maxY - minY
        switch handle {
        case .top, .bottom: w = h * ratio
        default: h = w / ratio
        }
        let anchorX: Double, anchorY: Double
        switch handle {
        case .topLeft: anchorX = maxX; anchorY = maxY
        case .topRight: anchorX = minX; anchorY = maxY
        case .bottomLeft: anchorX = maxX; anchorY = minY
        case .bottomRight: anchorX = minX; anchorY = minY
        case .left: anchorX = maxX; anchorY = (start.y + start.height / 2)
        case .right: anchorX = minX; anchorY = (start.y + start.height / 2)
        case .top: anchorX = start.x + start.width / 2; anchorY = maxY
        default: anchorX = start.x + start.width / 2; anchorY = minY
        }
        // Largest size that keeps the ratio and stays inside the source.
        let growsLeft = [.topLeft, .bottomLeft, .left].contains(handle)
        let growsUp = [.topLeft, .topRight, .top].contains(handle)
        let centeredX = handle == .top || handle == .bottom
        let centeredY = handle == .left || handle == .right
        let roomX = centeredX ? 2 * min(anchorX, 1 - anchorX) : (growsLeft ? anchorX : 1 - anchorX)
        let roomY = centeredY ? 2 * min(anchorY, 1 - anchorY) : (growsUp ? anchorY : 1 - anchorY)
        let fit = min(1, roomX / max(w, 1e-9), roomY / max(h, 1e-9))
        w *= fit; h *= fit
        let x = centeredX ? anchorX - w / 2 : (growsLeft ? anchorX - w : anchorX)
        let y = centeredY ? anchorY - h / 2 : (growsUp ? anchorY - h : anchorY)
        return UnitRect(x: x, y: y, width: w, height: h)
    }

    /// Largest rect with `unitRatio` inside `rect`, centered on it.
    public static func conform(_ rect: UnitRect, unitRatio: Double) -> UnitRect {
        var w = rect.width, h = rect.width / unitRatio
        if h > rect.height { h = rect.height; w = h * unitRatio }
        return UnitRect(x: rect.x + (rect.width - w) / 2, y: rect.y + (rect.height - h) / 2, width: w, height: h)
    }
}
