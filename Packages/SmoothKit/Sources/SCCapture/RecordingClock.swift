import CoreMedia
import Synchronization

/// Maps host-clock timestamps (sample buffers, input events) to media time, honoring pauses.
/// Media time 0 is the first written video frame.
public final class RecordingClock: Sendable {
    private struct State {
        var origin: CMTime?
        var pausedTotal = CMTime.zero
        var pauseStartedAt: CMTime?
    }

    private let state = Mutex(State())
    public let hostClock: CMClock

    public init(hostClock: CMClock = CMClockGetHostTimeClock()) {
        self.hostClock = hostClock
    }

    public var now: CMTime { CMClockGetTime(hostClock) }

    public var isStarted: Bool { state.withLock { $0.origin != nil } }
    public var isPaused: Bool { state.withLock { $0.pauseStartedAt != nil } }

    /// Sets media time 0 if not yet set. Returns true when this call started the clock.
    @discardableResult
    public func startIfNeeded(at host: CMTime) -> Bool {
        state.withLock {
            guard $0.origin == nil else { return false }
            $0.origin = host
            return true
        }
    }

    public func pause(at host: CMTime? = nil) {
        let t = host ?? now
        state.withLock { if $0.pauseStartedAt == nil, $0.origin != nil { $0.pauseStartedAt = t } }
    }

    public func resume(at host: CMTime? = nil) {
        let t = host ?? now
        state.withLock {
            guard let started = $0.pauseStartedAt else { return }
            $0.pausedTotal = $0.pausedTotal + (t - started)
            $0.pauseStartedAt = nil
        }
    }

    /// Media time for a host timestamp; nil before start or while paused.
    public func mediaTime(forHost host: CMTime) -> CMTime? {
        state.withLock { s in
            guard let origin = s.origin, s.pauseStartedAt == nil, host >= origin else { return nil }
            return host - origin - s.pausedTotal
        }
    }

    /// Elapsed media time "now", frozen while paused.
    public var elapsed: CMTime {
        let t = now
        return state.withLock { s in
            guard let origin = s.origin else { return .zero }
            let end = s.pauseStartedAt ?? t
            return CMTimeMaximum(.zero, end - origin - s.pausedTotal)
        }
    }
}
