import Foundation

extension Easing {
    /// Maps linear progress `t` (0...1) to eased progress. Springs may overshoot 1 slightly.
    public func value(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear: return x
        case .easeIn: return Self.bezier(0.42, 0, 1, 1, x)
        case .easeOut: return Self.bezier(0, 0, 0.58, 1, x)
        case .easeInOut: return Self.bezier(0.42, 0, 0.58, 1, x)
        case let .cubicBezier(x1, y1, x2, y2): return Self.bezier(x1, y1, x2, y2, x)
        case let .spring(params): return params.normalizedResponse(x)
        }
    }

    /// CSS-style cubic bezier with endpoints (0,0) and (1,1). Solves x(s) = t, returns y(s).
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ t: Double) -> Double {
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        func sampleX(_ s: Double) -> Double { ((ax * s + bx) * s + cx) * s }
        func sampleY(_ s: Double) -> Double { ((ay * s + by) * s + cy) * s }
        func slopeX(_ s: Double) -> Double { (3 * ax * s + 2 * bx) * s + cx }

        // Newton–Raphson first, bisection as a fallback for flat slopes.
        var s = t
        for _ in 0..<8 {
            let error = sampleX(s) - t
            if abs(error) < 1e-7 { return sampleY(s) }
            let d = slopeX(s)
            if abs(d) < 1e-6 { break }
            s -= error / d
        }
        var lo = 0.0, hi = 1.0
        s = t
        for _ in 0..<40 {
            let x = sampleX(s)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return sampleY(s)
    }
}

extension SpringParams {
    /// Undamped angular frequency and damping ratio.
    var omega0: Double { (stiffness / max(mass, 1e-6)).squareRoot() }
    var zeta: Double { damping / (2 * (stiffness * max(mass, 1e-6)).squareRoot()) }

    /// Position of a spring released from 0 towards 1 after `t` seconds.
    public func stepResponse(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = omega0, z = zeta
        if z < 1 {
            let wd = w0 * (1 - z * z).squareRoot()
            return 1 - exp(-z * w0 * t) * (cos(wd * t) + (z * w0 / wd) * sin(wd * t))
        } else if z == 1 {
            return 1 - exp(-w0 * t) * (1 + w0 * t)
        } else {
            let root = (z * z - 1).squareRoot()
            let r1 = -w0 * (z - root), r2 = -w0 * (z + root)
            return 1 + (r2 * exp(r1 * t) - r1 * exp(r2 * t)) / (r1 - r2)
        }
    }

    /// Seconds until the response stays within 0.1% of the target.
    public var settleTime: Double {
        let w0 = omega0, z = zeta
        let decay = z < 1 ? z * w0 : w0 * (z - (z * z - 1).squareRoot()) // slowest exponential
        return -log(0.001) / max(decay, 1e-6)
    }

    /// The spring's motion stretched to fit 0...1, so it can be used as an easing curve of any duration.
    public func normalizedResponse(_ x: Double) -> Double {
        x >= 1 ? 1 : stepResponse(at: x * settleTime)
    }
}
