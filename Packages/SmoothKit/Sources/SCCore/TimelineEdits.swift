import Foundation

/// Anything that sits on a timeline track as a time range (zooms, camera shots).
public protocol TimelineItem: Identifiable where ID == UUID {
    var range: TimeRange { get set }
    /// Called after a user edit (zooms become manual so regenerating keeps them).
    mutating func markEdited()
}

extension ZoomSegment: TimelineItem {
    public mutating func markEdited() { origin = .manual }
}

extension CameraClip: TimelineItem {
    public mutating func markEdited() {}
}

public typealias ZoomEdits = TimelineEdits

/// Pure timeline editing operations, shared by the timeline UI and tests.
public enum TimelineEdits {
    public static let minDuration: Seconds = 0.4

    /// Moves the zooms in `ids` by `delta`, as a group, keeping them inside the recording.
    /// A single zoom also stops at its neighbours instead of overlapping them.
    public static func move<T: TimelineItem>(_ zooms: [T], ids: Set<UUID>, by delta: Seconds, duration: Seconds) -> [T] {
        let moving = zooms.filter { ids.contains($0.id) }
        guard let first = moving.map(\.range.start).min(), let last = moving.map(\.range.end).max() else { return zooms }
        var d = min(max(delta, -first), duration - last)
        if moving.count == 1, let z = moving.first {
            let others = zooms.filter { !ids.contains($0.id) }
            let before = others.filter { $0.range.end <= z.range.start + 1e-9 }.map(\.range.end).max() ?? 0
            let after = others.filter { $0.range.start >= z.range.end - 1e-9 }.map(\.range.start).min() ?? duration
            d = min(max(d, before - z.range.start), after - z.range.end)
        }
        return zooms.map { z in
            guard ids.contains(z.id) else { return z }
            var m = z
            m.range = TimeRange(start: z.range.start + d, end: z.range.end + d)
            m.markEdited()
            return m
        }
    }

    public enum Edge: Sendable { case start, end }

    /// Drags one edge of a zoom to `time`, clamped to its neighbours and a minimum length.
    public static func resize<T: TimelineItem>(_ zooms: [T], id: UUID, edge: Edge, to time: Seconds, duration: Seconds) -> [T] {
        guard let z = zooms.first(where: { $0.id == id }) else { return zooms }
        let others = zooms.filter { $0.id != id }
        var range = z.range
        switch edge {
        case .start:
            let limit = others.filter { $0.range.end <= z.range.start + 1e-9 }.map(\.range.end).max() ?? 0
            range.start = min(max(time, limit), z.range.end - minDuration)
        case .end:
            let limit = others.filter { $0.range.start >= z.range.end - 1e-9 }.map(\.range.start).min() ?? duration
            range.end = max(min(time, limit), z.range.start + minDuration)
        }
        return zooms.map { s in
            guard s.id == id else { return s }
            var m = s
            m.range = range
            m.markEdited()
            return m
        }
    }

    /// Applies `change` to every zoom in `ids` and marks them manual (so regenerating keeps them).
    public static func update<T: TimelineItem>(_ zooms: [T], ids: Set<UUID>, _ change: (inout T) -> Void) -> [T] {
        zooms.map { z in
            guard ids.contains(z.id) else { return z }
            var m = z
            change(&m)
            m.markEdited()
            return m
        }
    }

    /// Free range of up to `length` starting at `time`, or nil if `time` is inside an item.
    public static func freeRange<T: TimelineItem>(at time: Seconds, in items: [T], duration: Seconds, length: Seconds) -> TimeRange? {
        guard !items.contains(where: { $0.range.contains(time) }) else { return nil }
        let before = items.filter { $0.range.end <= time }.map(\.range.end).max() ?? 0
        let after = items.filter { $0.range.start > time }.map(\.range.start).min() ?? duration
        let start = max(time, before)
        let end = min(start + length, after)
        return end - start >= minDuration ? TimeRange(start: start, end: end) : nil
    }

    /// A new zoom at `time`, sized to fit the free space around it. Nil if there's no room.
    public static func insertion(at time: Seconds, in zooms: [ZoomSegment], duration: Seconds, length: Seconds = 2.5) -> ZoomSegment? {
        freeRange(at: time, in: zooms, duration: duration, length: length).map { ZoomSegment(range: $0, origin: .manual) }
    }
}

public enum Snapping {
    /// The candidate closest to `time` within `threshold`, else `time`.
    public static func snap(_ time: Seconds, to candidates: [Seconds], threshold: Seconds) -> Seconds {
        guard let best = candidates.min(by: { abs($0 - time) < abs($1 - time) }), abs(best - time) <= threshold else { return time }
        return best
    }

    /// Delta that snaps either end of a moving range onto a candidate.
    public static func snapDelta(range: TimeRange, delta: Seconds, candidates: [Seconds], threshold: Seconds) -> Seconds {
        var best = delta
        var bestDistance = threshold
        for edge in [range.start, range.end] {
            let moved = edge + delta
            for c in candidates where abs(c - moved) < bestDistance {
                bestDistance = abs(c - moved)
                best = c - edge
            }
        }
        return best
    }
}

/// Kept ranges of the recording (`Project.cuts`; empty means "everything").
public enum Cuts {
    public static let minDuration: Seconds = 0.1

    public static func kept(_ project: Project) -> [TimeRange] {
        project.cuts.isEmpty ? [TimeRange(start: 0, end: project.recording.duration)] : project.cuts.sorted { $0.start < $1.start }
    }

    /// Total length after cuts.
    public static func editedDuration(_ project: Project) -> Seconds {
        kept(project).map(\.duration).reduce(0, +)
    }

    /// Splits the kept range under `time` in two. Returns nil if `time` isn't inside one (with margin).
    public static func split(_ project: Project, at time: Seconds) -> [TimeRange]? {
        var ranges = kept(project)
        guard let i = ranges.firstIndex(where: { time > $0.start + minDuration && time < $0.end - minDuration }) else { return nil }
        let r = ranges[i]
        ranges.replaceSubrange(i...i, with: [TimeRange(start: r.start, end: time), TimeRange(start: time, end: r.end)])
        return ranges
    }

    /// Removes a kept range (a clip). The last clip can't be removed.
    public static func remove(_ project: Project, index: Int) -> [TimeRange]? {
        var ranges = kept(project)
        guard ranges.count > 1, ranges.indices.contains(index) else { return nil }
        ranges.remove(at: index)
        return ranges
    }

    /// Moves one edge of clip `index`, clamped to its neighbours and the recording.
    public static func trim(_ project: Project, index: Int, edge: ZoomEdits.Edge, to time: Seconds) -> [TimeRange] {
        var ranges = kept(project)
        guard ranges.indices.contains(index) else { return ranges }
        let r = ranges[index]
        switch edge {
        case .start:
            let limit = index > 0 ? ranges[index - 1].end : 0
            ranges[index].start = min(max(time, limit), r.end - minDuration)
        case .end:
            let limit = index + 1 < ranges.count ? ranges[index + 1].start : project.recording.duration
            ranges[index].end = max(min(time, limit), r.start + minDuration)
        }
        return normalized(ranges, duration: project.recording.duration)
    }

    /// Collapses "everything kept" back to empty.
    static func normalized(_ ranges: [TimeRange], duration: Seconds) -> [TimeRange] {
        if ranges.count == 1, ranges[0].start <= 1e-6, ranges[0].end >= duration - 1e-6 { return [] }
        return ranges
    }

    /// Source time shown at `output` seconds into the edited video.
    public static func sourceTime(forOutput output: Seconds, in ranges: [TimeRange]) -> Seconds {
        var remaining = output
        for r in ranges {
            if remaining < r.duration { return r.start + max(remaining, 0) }
            remaining -= r.duration
        }
        return ranges.last?.end ?? output
    }

    /// Position in the edited video of a source time, or nil if that moment was cut.
    public static func outputTime(forSource source: Seconds, in ranges: [TimeRange]) -> Seconds? {
        var offset = 0.0
        for r in ranges {
            if r.contains(source) { return offset + source - r.start }
            offset += r.duration
        }
        return nil
    }

    /// Where playback continues after `time` if it falls in a removed region (nil = past the end).
    public static func nextKeptTime(after time: Seconds, in ranges: [TimeRange]) -> Seconds? {
        if ranges.contains(where: { $0.contains(time) }) { return time }
        return ranges.first { $0.start >= time }?.start
    }
}
