import CoreGraphics
import Foundation

/// Places zoom segments automatically from what happened during the recording.
///
/// 1. Collect moments of interest: clicks, typing bursts, shortcuts and (at high sensitivity)
///    places where the cursor comes to rest after travelling.
/// 2. Give each a time window (zoom in shortly before, hold a little after).
/// 3. Merge windows that are close in time into one zoom that follows the cursor.
/// 4. Keep clusters with enough weight for the chosen sensitivity, and lower the zoom level
///    when a cluster's action is spread out so it still fits in view.
public enum AutoZoom {
    struct Interest {
        var start: Seconds
        var end: Seconds
        var position: CGPoint
        var weight: Double
    }

    public static func segments(telemetry: Telemetry, duration: Seconds, settings: AutoZoomSettings) -> [ZoomSegment] {
        let s = min(max(settings.sensitivity, 0), 1)
        let target = CGSize(width: telemetry.header.targetSize.width, height: telemetry.header.targetSize.height)
        var interests = clicks(telemetry) + typing(telemetry, sensitivity: s)
        if s >= 0.6 { interests += dwells(telemetry, sensitivity: s) }
        interests = interests.filter { inside($0.position, target) }.sorted { $0.start < $1.start }
        guard !interests.isEmpty else { return [] }

        // Merge interests whose windows are close in time.
        var clusters: [[Interest]] = []
        for interest in interests {
            if let last = clusters.last?.map(\.end).max(), interest.start - last <= settings.mergeGap {
                clusters[clusters.count - 1].append(interest)
            } else {
                clusters.append([interest])
            }
        }

        let threshold = s < 0.2 ? 2.0 : 1.0 - 0.5 * s
        let transitionIn = 0.7, transitionOut = 0.8
        var segments: [ZoomSegment] = []
        for cluster in clusters where cluster.map(\.weight).reduce(0, +) >= threshold - 1e-9 {
            var start = max(cluster.map(\.start).min()!, 0)
            var end = min(cluster.map(\.end).max()!, duration)
            if end - start < settings.minSegmentDuration {
                let pad = (settings.minSegmentDuration - (end - start)) / 2
                start = max(start - pad, 0)
                end = min(end + pad, duration)
            }
            guard end - start >= transitionIn + 0.2 else { continue }
            segments.append(ZoomSegment(
                range: TimeRange(start: start, end: end),
                scale: fittingScale(for: cluster.map(\.position), target: target, preferred: settings.defaultScale),
                focus: .followCursor(deadZone: 0.22),
                easing: .default,
                transitionIn: transitionIn,
                transitionOut: transitionOut,
                followSpring: .gentle,
                origin: .auto
            ))
        }
        return segments
    }

    /// Replaces the project's automatic zooms with fresh ones, keeping manual zooms and any time
    /// they occupy.
    public static func regenerate(_ project: inout Project, telemetry: Telemetry) {
        let manual = project.zooms.filter { $0.origin == .manual }
        var auto = project.autoZoom.enabled
            ? segments(telemetry: telemetry, duration: project.recording.duration, settings: project.autoZoom)
            : []
        auto.removeAll { a in manual.contains { m in a.range.start < m.range.end && m.range.start < a.range.end } }
        project.zooms = (manual + auto).sorted { $0.range.start < $1.range.start }
        project.autoZoomGenerated = true
    }

    // MARK: Interest detection

    static func clicks(_ t: Telemetry) -> [Interest] {
        t.events.filter { $0.kind == .mouseDown || $0.kind == .rightDown }.map { e in
            Interest(start: e.time - 0.9, end: e.time + 1.6, position: CGPoint(x: Double(e.x), y: Double(e.y)), weight: 1)
        }
    }

    /// Bursts of typing focus on the last click before them (usually the text field), or the cursor.
    static func typing(_ t: Telemetry, sensitivity s: Double) -> [Interest] {
        let commandMask: UInt32 = 0x100000 | 0x40000 // ⌘ or ⌃
        let minKeys = s > 0.66 ? 2 : s > 0.33 ? 3 : 5
        var lastClick: CGPoint?
        var lastCursor = CGPoint.zero
        var result: [Interest] = []
        var burst: [Seconds] = []
        var burstFocus = CGPoint.zero

        func flush() {
            if burst.count >= minKeys, let first = burst.first, let last = burst.last {
                result.append(Interest(start: first - 0.6, end: last + 1.2, position: burstFocus, weight: 1))
            }
            burst.removeAll()
        }

        for e in t.events {
            let p = CGPoint(x: Double(e.x), y: Double(e.y))
            switch e.kind {
            case .move:
                lastCursor = p
            case .mouseDown, .rightDown:
                lastClick = p
            case .keyDown:
                if e.modifiers & commandMask != 0 {
                    // A shortcut: a light moment of interest on its own.
                    result.append(Interest(start: e.time - 0.5, end: e.time + 1.0, position: lastCursor, weight: 0.5))
                    continue
                }
                if let last = burst.last, e.time - last > 1.5 { flush() }
                if burst.isEmpty { burstFocus = lastClick ?? lastCursor }
                burst.append(e.time)
            default:
                break
            }
        }
        flush()
        return result
    }

    /// The cursor travels, then rests for a while: whatever it points at is probably being shown.
    static func dwells(_ t: Telemetry, sensitivity s: Double) -> [Interest] {
        let moves = t.events.filter { $0.kind == .move }
        guard moves.count > 2 else { return [] }
        let minRest = 1.6 - 0.6 * s
        var result: [Interest] = []
        var travelStart = CGPoint(x: Double(moves[0].x), y: Double(moves[0].y))
        for (a, b) in zip(moves, moves.dropFirst()) {
            let rest = b.time - a.time
            let p = CGPoint(x: Double(a.x), y: Double(a.y))
            if rest >= minRest {
                if hypot(p.x - travelStart.x, p.y - travelStart.y) > 150 {
                    result.append(Interest(start: a.time - 0.4, end: a.time + min(rest, 2.5), position: p, weight: 0.5))
                }
                travelStart = CGPoint(x: Double(b.x), y: Double(b.y))
            }
        }
        return result
    }

    /// The preferred zoom, lowered until every point of interest fits in view with some margin.
    static func fittingScale(for points: [CGPoint], target: CGSize, preferred: Double) -> Double {
        guard points.count > 1 else { return preferred }
        let xs = points.map(\.x), ys = points.map(\.y)
        let spanX = (xs.max()! - xs.min()!) * 1.35, spanY = (ys.max()! - ys.min()!) * 1.35
        let fit = min(target.width / max(spanX, 1), target.height / max(spanY, 1))
        return max(min(preferred, fit), min(1.3, preferred))
    }

    private static func inside(_ p: CGPoint, _ size: CGSize) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height
    }
}
