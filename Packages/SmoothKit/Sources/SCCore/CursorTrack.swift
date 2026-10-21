import CoreGraphics
import Foundation

/// The cursor's motion and look over a whole recording, precomputed from telemetry so any frame
/// can be evaluated instantly and deterministically (preview and export agree exactly).
///
/// Positions are in capture-target points (origin top-left), like the telemetry.
public struct CursorTrack: Sendable {
    public struct Sprite: Hashable, Sendable {
        public var imageURL: URL
        /// Hotspot and size in points.
        public var hotspot: CGPoint
        public var size: CGSize
    }

    public struct Click: Sendable {
        public var time: Seconds
        public var position: CGPoint
        public var isRight: Bool
    }

    /// Cursor at one instant.
    public struct State: Sendable {
        public var position: CGPoint
        /// Points per second.
        public var velocity: CGVector
        public var sprite: Sprite?
        public var opacity: Double
        /// 1 = normal size; dips while the button is held (press effect).
        public var pressScale: Double
        /// Radians, from horizontal motion.
        public var rotation: Double
    }

    public let targetSize: CGSize
    public let clicks: [Click]
    public let settings: CursorSettings

    static let rate = 240.0
    private let raw: [(time: Seconds, position: CGPoint, sprite: Int)]
    private let smoothed: [SIMD4<Double>] // x, y, vx, vy at `rate`
    private let sprites: [Sprite]
    private let presses: [TimeRange]
    private let idleGaps: [TimeRange]

    public var isEmpty: Bool { raw.isEmpty }
    public var duration: Seconds { Double(max(smoothed.count - 1, 0)) / Self.rate }

    /// - Parameters:
    ///   - sprites: resolved image per telemetry sprite index (system or replaced by a cursor pack).
    public init(telemetry: Telemetry, settings: CursorSettings, sprites: [Sprite], duration: Seconds) {
        self.settings = settings
        self.sprites = sprites
        targetSize = CGSize(width: telemetry.header.targetSize.width, height: telemetry.header.targetSize.height)

        var raw: [(Seconds, CGPoint, Int)] = []
        var clicks: [Click] = []
        var presses: [TimeRange] = []
        var pressStart: Seconds?
        for e in telemetry.events {
            let p = CGPoint(x: Double(e.x), y: Double(e.y))
            switch e.kind {
            case .move:
                raw.append((e.time, p, Int(e.code)))
            case .mouseDown, .rightDown:
                clicks.append(Click(time: e.time, position: p, isRight: e.kind == .rightDown))
                pressStart = e.time
            case .mouseUp, .rightUp:
                if let start = pressStart { presses.append(TimeRange(start: start, end: max(e.time, start + 0.06))) }
                pressStart = nil
            default:
                break
            }
        }
        if let start = pressStart { presses.append(TimeRange(start: start, end: start + 0.12)) }
        self.raw = raw.map { (time: $0.0, position: $0.1, sprite: $0.2) }
        self.clicks = clicks
        self.presses = presses

        let length = max(duration, raw.last?.0 ?? 0)
        smoothed = Self.anchorToClicks(
            Self.simulate(raw: self.raw, length: length, settings: settings), raw: self.raw, clicks: clicks
        )
        idleGaps = Self.idleGaps(raw: self.raw, clicks: clicks, length: length, delay: settings.idleDelay)
    }

    // MARK: Evaluation

    public func state(at time: Seconds) -> State? {
        guard !raw.isEmpty, !smoothed.isEmpty else { return nil }
        let s = sample(smoothed, at: time)
        let position = settings.smoothingAmount > 0.001 ? CGPoint(x: s.x, y: s.y) : rawPosition(at: time)
        let velocity = CGVector(dx: s.z, dy: s.w)
        let spriteIndex = rawSprite(at: time)
        let rotation = settings.tiltWithMotion ? Self.maxTilt * tanh(s.z / 1800) : 0
        return State(
            position: position, velocity: velocity,
            sprite: sprites.indices.contains(spriteIndex) ? sprites[spriteIndex] : sprites.first,
            opacity: opacity(at: time, position: position),
            pressScale: settings.clickEffect == .press ? 1 - 0.18 * pressAmount(at: time) : 1 - 0.06 * pressAmount(at: time),
            rotation: rotation
        )
    }

    /// Where the cursor is drawn at `time` (smoothed, or raw when smoothing is off).
    public func displayedPosition(at time: Seconds) -> CGPoint? {
        guard !raw.isEmpty, !smoothed.isEmpty else { return nil }
        if settings.smoothingAmount <= 0.001 { return rawPosition(at: time) }
        let s = sample(smoothed, at: time)
        return CGPoint(x: s.x, y: s.y)
    }

    /// Clicks whose effect is still animating at `time`, with progress 0...1.
    public func activeClicks(at time: Seconds, duration: Seconds = Self.clickEffectDuration) -> [(click: Click, progress: Double)] {
        guard settings.clickEffect == .ripple || settings.clickEffect == .pulse else { return [] }
        var result: [(Click, Double)] = []
        var lo = 0, hi = clicks.count
        while lo < hi { let mid = (lo + hi) / 2; if clicks[mid].time < time - duration { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < clicks.count, clicks[i].time <= time {
            result.append((clicks[i], (time - clicks[i].time) / duration))
            i += 1
        }
        return result
    }

    public static let clickEffectDuration: Seconds = 0.55
    static let maxTilt = 0.22 // ~12.5°

    // MARK: Raw lookup

    private func rawIndex(at time: Seconds) -> Int {
        var lo = 0, hi = raw.count
        while lo < hi { let mid = (lo + hi) / 2; if raw[mid].time <= time { lo = mid + 1 } else { hi = mid } }
        return max(lo - 1, 0)
    }

    private func rawPosition(at time: Seconds) -> CGPoint { Self.rawPosition(raw, at: time, index: rawIndex(at: time)) }

    private func rawSprite(at time: Seconds) -> Int { raw[rawIndex(at: time)].sprite }

    /// Linear between close samples; holds across gaps (the cursor wasn't moving).
    private static func rawPosition(_ raw: [(time: Seconds, position: CGPoint, sprite: Int)], at time: Seconds, index i: Int) -> CGPoint {
        let a = raw[i]
        guard time > a.time, i + 1 < raw.count else { return a.position }
        let b = raw[i + 1]
        let gap = b.time - a.time
        guard gap > 0, gap < 0.05 else { return a.position }
        let f = (time - a.time) / gap
        return CGPoint(x: a.position.x + (b.position.x - a.position.x) * f, y: a.position.y + (b.position.y - a.position.y) * f)
    }

    private func sample(_ path: [SIMD4<Double>], at time: Seconds) -> SIMD4<Double> {
        let i = time * Self.rate
        let a = Int(min(max(floor(i), 0), Double(path.count - 1)))
        let b = min(a + 1, path.count - 1)
        let f = min(max(i - Double(a), 0), 1)
        return path[a] + (path[b] - path[a]) * f
    }

    // MARK: Opacity & press

    private func opacity(at time: Seconds, position: CGPoint) -> Double {
        guard settings.visible else { return 0 }
        // Off the recorded area (e.g. on another display).
        let margin = 2.0
        if position.x < -margin || position.y < -margin || position.x > targetSize.width + margin || position.y > targetSize.height + margin {
            return 0
        }
        guard settings.hideWhenIdle else { return 1 }
        let fade = 0.25
        for gap in idleGaps where time >= gap.start - fade && time <= gap.end + fade {
            // Fade out after the idle delay; fade back in just *before* the cursor moves again.
            let out = smoothstep((time - gap.start) / fade)
            let back = smoothstep((gap.end - time) / fade)
            return 1 - min(out, back)
        }
        return 1
    }

    private func pressAmount(at time: Seconds) -> Double {
        for p in presses where time >= p.start - 0.01 && time <= p.end + 0.2 {
            if time < p.start + 0.08 { return smoothstep((time - p.start) / 0.08) }
            if time <= p.end { return 1 }
            return 1 - smoothstep((time - p.end) / 0.2)
        }
        return 0
    }

    // MARK: Precomputation

    /// The spring's steady-state delay. The spring chases the path this far in the future,
    /// so the smoothed cursor doesn't trail behind the real one.
    static func lookahead(omega: Double, zeta: Double) -> Seconds {
        min(2 * zeta / omega, 0.3)
    }

    /// Pulls the smoothed path onto the exact click positions around each click, so the cursor
    /// is precisely on the button it presses.
    static func anchorToClicks(_ path: [SIMD4<Double>], raw: [(time: Seconds, position: CGPoint, sprite: Int)], clicks: [Click]) -> [SIMD4<Double>] {
        guard !clicks.isEmpty, !raw.isEmpty else { return path }
        var out = path
        let window = 0.18
        for click in clicks {
            let first = max(Int(((click.time - window) * rate).rounded(.down)), 0)
            let last = min(Int(((click.time + window) * rate).rounded(.up)), out.count - 1)
            guard first <= last else { continue }
            var index = 0
            for i in first...last {
                let t = Double(i) / rate
                while index + 1 < raw.count, raw[index + 1].time <= t { index += 1 }
                let target = rawPosition(raw, at: t, index: index)
                let w = smoothstep(1 - abs(t - click.time) / window)
                out[i].x += (Double(target.x) - out[i].x) * w
                out[i].y += (Double(target.y) - out[i].y) * w
            }
        }
        return out
    }

    /// Spring follower: higher smoothing → lower natural frequency; damping ratio from the chosen spring.
    static func simulate(raw: [(time: Seconds, position: CGPoint, sprite: Int)], length: Seconds, settings: CursorSettings) -> [SIMD4<Double>] {
        guard let first = raw.first else { return [] }
        let amount = min(max(settings.smoothingAmount, 0), 1)
        let omega = 45 * pow(5.5 / 45, amount) // 45 rad/s (tight) … 5.5 rad/s (floaty)
        let zeta = min(max(settings.smoothing.zeta, 0.35), 1.6)
        let dt = 1 / rate
        let lead = lookahead(omega: omega, zeta: zeta)
        let steps = Int((length * rate).rounded(.up)) + 1
        var out = [SIMD4<Double>](repeating: .zero, count: steps)
        var p = SIMD2<Double>(Double(first.position.x), Double(first.position.y))
        var v = SIMD2<Double>.zero
        var index = 0
        // Sub-steps keep stiff springs stable.
        let substeps = 4
        let h = dt / Double(substeps)
        for step in 0..<steps {
            let t = Double(step) * dt + lead
            while index + 1 < raw.count, raw[index + 1].time <= t { index += 1 }
            let target = rawPosition(raw, at: t, index: index)
            let goal = SIMD2<Double>(Double(target.x), Double(target.y))
            for _ in 0..<substeps {
                let a = (goal - p) * (omega * omega) - v * (2 * zeta * omega)
                v += a * h
                p += v * h
            }
            out[step] = SIMD4<Double>(p.x, p.y, v.x, v.y)
        }
        return out
    }

    /// Stretches with no movement or clicks longer than `delay`; the cursor hides inside them.
    static func idleGaps(raw: [(time: Seconds, position: CGPoint, sprite: Int)], clicks: [Click], length: Seconds, delay: Seconds) -> [TimeRange] {
        var activity: [Seconds] = [0]
        var last: CGPoint?
        for r in raw {
            if let l = last, hypot(r.position.x - l.x, r.position.y - l.y) < 0.5 { continue }
            activity.append(r.time)
            last = r.position
        }
        activity += clicks.map(\.time)
        activity.append(length + delay + 1)
        activity.sort()
        var gaps: [TimeRange] = []
        for (a, b) in zip(activity, activity.dropFirst()) where b - a > delay + 0.5 {
            gaps.append(TimeRange(start: a + delay, end: b))
        }
        return gaps
    }
}

@inline(__always) func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}
