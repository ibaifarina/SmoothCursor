import CoreGraphics
import Foundation

/// Where the virtual camera is, relative to the phone (which sits at the origin facing +z).
/// Angles in radians; `distance` is a multiple of the distance at which the phone just fits the frame.
public struct Camera3D: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    public var distance: Double
    /// Look-at offset from the phone's center, in phone half-heights.
    public var target: CGPoint

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0, distance: Double = 1, target: CGPoint = .zero) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll; self.distance = distance; self.target = target
    }

    public static let front = Camera3D()

    /// Blend; distance interpolates geometrically so dollies feel even.
    public static func mix(_ a: Camera3D, _ b: Camera3D, _ t: Double) -> Camera3D {
        Camera3D(
            yaw: a.yaw + (b.yaw - a.yaw) * t,
            pitch: a.pitch + (b.pitch - a.pitch) * t,
            roll: a.roll + (b.roll - a.roll) * t,
            distance: a.distance * pow(b.distance / max(a.distance, 1e-6), t),
            target: CGPoint(x: a.target.x + (b.target.x - a.target.x) * t, y: a.target.y + (b.target.y - a.target.y) * t)
        )
    }
}

public enum MockupCamera {
    /// Camera for one shot, `u` = progress through the clip (0...1).
    /// `screenHalf` is the screen's half size in phone half-heights (for aiming close-ups).
    public static func shot(_ clip: CameraClip, progress u: Double, screenHalf: CGSize) -> Camera3D {
        let k = min(max(clip.intensity, 0), 1)
        let s = smoothstep(u) // motion inside a shot eases in and out too
        switch clip.preset {
        case .front:
            return Camera3D(distance: 1 - 0.04 * k * s)
        case .hero:
            return Camera3D(yaw: -0.44 + 0.14 * k * s, pitch: 0.17, roll: -0.05, distance: 1.06 - 0.05 * k * s, target: CGPoint(x: 0, y: -0.03))
        case .straightOn:
            // Facing, floating gently.
            let w = 2 * Double.pi * s
            return Camera3D(yaw: 0.07 * k * sin(w), pitch: 0.05 * k * sin(w * 0.5), distance: 0.97 - 0.05 * k * s)
        case .orbitLeft, .orbitRight:
            let sweep = 0.55 + 0.5 * k
            let yaw = (0.5 - s) * 2 * sweep * (clip.preset == .orbitLeft ? 1 : -1)
            return Camera3D(yaw: yaw, pitch: 0.12, distance: 1.04)
        case .tiltUp:
            return Camera3D(yaw: 0.22, pitch: -0.34 + (0.46 + 0.1 * k) * s, roll: 0.03, distance: 1.02)
        case .closeUp:
            let f = clip.focus ?? UnitPoint2D(x: 0.5, y: 0.3)
            let target = CGPoint(x: (f.x - 0.5) * 2 * screenHalf.width, y: (0.5 - f.y) * 2 * screenHalf.height)
            // Close enough to read the screen, far enough to keep the phone's edge in frame.
            return Camera3D(yaw: 0.16 - 0.08 * k * s, pitch: 0.07, roll: 0.02, distance: 0.66 - 0.1 * k * s,
                            target: CGPoint(x: target.x * 0.75, y: target.y * 0.75))
        }
    }

    /// Camera at `time`: the active shot, eased between consecutive shots. Shots closer together
    /// than their transition hand off directly; gaps rest on the plain front view.
    public static func camera(at time: Seconds, clips: [CameraClip], screenHalf: CGSize) -> Camera3D {
        let sorted = clips.filter { $0.range.duration > 0.01 }.sorted { $0.range.start < $1.range.start }
        guard !sorted.isEmpty else { return .front }

        func state(of index: Int?, at t: Seconds) -> Camera3D {
            guard let i = index else { return .front }
            let c = sorted[i]
            return shot(c, progress: (t - c.range.start) / c.range.duration, screenHalf: screenHalf)
        }

        // Boundaries where the shot changes: (time, duration, easing, shot before, shot after).
        var boundaries: [(time: Seconds, length: Seconds, easing: Easing, before: Int?, after: Int?)] = []
        for (i, c) in sorted.enumerated() {
            let previousEnd = i > 0 ? sorted[i - 1].range.end : -Double.infinity
            let length = min(c.transition, c.range.duration)
            if c.range.start - previousEnd < length {
                // Direct handoff from the previous shot, centered in the gap between them.
                let mid = (previousEnd + c.range.start) / 2
                boundaries.append((mid, max(length, c.range.start - previousEnd + 0.1), c.easing, i - 1, i))
            } else {
                if i > 0 { boundaries.append((previousEnd, min(sorted[i - 1].transition, sorted[i - 1].range.duration), sorted[i - 1].easing, i - 1, nil)) }
                boundaries.append((c.range.start, length, c.easing, nil, i))
            }
        }
        if let last = sorted.indices.last {
            boundaries.append((sorted[last].range.end, min(sorted[last].transition, sorted[last].range.duration), sorted[last].easing, last, nil))
        }

        for b in boundaries where b.length > 0 && abs(time - b.time) < b.length / 2 {
            let p = b.easing.value((time - (b.time - b.length / 2)) / b.length)
            let from = state(of: b.before, at: b.before.map { min(time, sorted[$0].range.end) } ?? time)
            let to = state(of: b.after, at: b.after.map { max(time, sorted[$0].range.start) } ?? time)
            return Camera3D.mix(from, to, p)
        }
        let active = sorted.firstIndex { $0.range.contains(time) }
        return state(of: active, at: time)
    }

    /// A ready-made shot list: close-ups on strong zooms, varied wide shots in between.
    /// Very short wide stretches are absorbed by their neighbours so no shot flashes by.
    public static func autoShots(duration: Seconds, zooms: [ZoomSegment]) -> [CameraClip] {
        guard duration > 0.5 else { return [] }
        let minShot = 1.5
        // Close-up windows from zooms strong enough to be worth a camera move.
        var closeUps: [(range: TimeRange, focus: UnitPoint2D?)] = []
        for zoom in zooms.sorted(by: { $0.range.start < $1.range.start }) where zoom.scale >= 1.6 {
            let range = TimeRange(start: max(zoom.range.start, closeUps.last?.range.end ?? 0), end: min(zoom.range.end, duration))
            guard range.duration >= minShot else { continue }
            let focus: UnitPoint2D? = if case let .fixed(p) = zoom.focus { p } else { nil }
            closeUps.append((range, focus))
        }

        let wide: [CameraPreset] = [.hero, .straightOn, .orbitLeft, .tiltUp, .orbitRight, .front]
        var clips: [CameraClip] = []
        var wideIndex = 0
        func addWide(_ start: Seconds, _ end: Seconds) {
            var t = start
            while end - t > 1e-6 {
                let remaining = end - t
                let length = remaining > 9 ? min(6, remaining / 2) : remaining
                clips.append(CameraClip(range: TimeRange(start: t, end: t + length), preset: wide[wideIndex % wide.count], intensity: 0.5, transition: 1.0))
                wideIndex += 1
                t += length
            }
        }

        var cursor = 0.0
        for close in closeUps {
            var start = close.range.start
            let gap = start - cursor
            if gap >= minShot {
                addWide(cursor, start)
            } else if gap > 0 {
                // Too short for its own shot: the close-up starts early (or the previous one runs on).
                if clips.last?.preset == .closeUp, var last = clips.popLast() {
                    last.range.end = start
                    clips.append(last)
                } else {
                    start = cursor
                }
            }
            clips.append(CameraClip(range: TimeRange(start: start, end: close.range.end), preset: .closeUp, intensity: 0.4, transition: 0.9, focus: close.focus))
            cursor = close.range.end
        }
        if duration - cursor >= minShot || clips.isEmpty {
            addWide(cursor, duration)
        } else if var last = clips.popLast() {
            last.range.end = duration
            clips.append(last)
        }
        return clips
    }
}
