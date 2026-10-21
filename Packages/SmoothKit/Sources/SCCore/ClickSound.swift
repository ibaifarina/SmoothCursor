import Foundation

/// The synthesized mouse click mixed into exports and played in the preview.
public enum ClickSound {
    public static let sampleRate = 48_000.0

    /// A short, soft "tick": a damped high partial over a little body, with a noise transient. Mono.
    public static let samples: [Float] = {
        let n = Int(0.035 * sampleRate)
        var state: UInt32 = 0x1234_5678
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: state)) / Double(Int32.max)
            let tick = sin(2 * .pi * 2600 * t) * exp(-t / 0.0035) * 0.55
            let body = sin(2 * .pi * 210 * t) * exp(-t / 0.009) * 0.35
            let transient = noise * exp(-t / 0.0012) * 0.3
            return Float((tick + body + transient) * 0.5)
        }
    }()
}
