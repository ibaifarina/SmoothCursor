import Foundation

/// Finds the boring parts: nothing moves, nothing is clicked or typed, nobody talks.
public enum IdleTrim {
    /// Kept ranges with idle stretches longer than `minIdle` removed (keeping `padding` on each side).
    /// `peaks` is the audio envelope at `peakRate` per second (0...1); silence is below `silence`.
    public static func keptRanges(
        project: Project, telemetry: Telemetry?, peaks: [Float], peakRate: Double = 100,
        minIdle: Seconds = 2.5, padding: Seconds = 0.4, silence: Float = 0.12
    ) -> [TimeRange] {
        let duration = project.recording.duration
        var activity: [Seconds] = [0, duration]
        if let telemetry {
            var last: (Float, Float)?
            for e in telemetry.events {
                if e.kind == .move {
                    if let l = last, abs(l.0 - e.x) + abs(l.1 - e.y) < 1 { continue }
                    last = (e.x, e.y)
                }
                activity.append(e.time)
            }
        }
        for (i, p) in peaks.enumerated() where p > silence { activity.append(Double(i) / peakRate) }
        activity.sort()

        var removed: [TimeRange] = []
        for (a, b) in zip(activity, activity.dropFirst()) where b - a > minIdle {
            removed.append(TimeRange(start: a + padding, end: b - padding))
        }
        return subtract(removed, from: Cuts.kept(project))
    }

    static func subtract(_ removed: [TimeRange], from kept: [TimeRange]) -> [TimeRange] {
        var result = kept
        for r in removed {
            result = result.flatMap { k -> [TimeRange] in
                guard r.start < k.end, r.end > k.start else { return [k] }
                var parts: [TimeRange] = []
                if r.start - k.start > Cuts.minDuration { parts.append(TimeRange(start: k.start, end: r.start)) }
                if k.end - r.end > Cuts.minDuration { parts.append(TimeRange(start: r.end, end: k.end)) }
                return parts
            }
        }
        return result.isEmpty ? kept : result
    }
}
