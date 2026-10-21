import CoreMedia
import Testing
@testable import SCCapture

@Suite struct RecordingClockTests {
    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    @Test func mapsHostTimeAndSkipsPauses() {
        let clock = RecordingClock()
        #expect(clock.mediaTime(forHost: t(100)) == nil) // not started
        #expect(clock.startIfNeeded(at: t(100)))
        #expect(!clock.startIfNeeded(at: t(101)))
        #expect(clock.mediaTime(forHost: t(102)) == t(2))
        clock.pause(at: t(103))
        #expect(clock.mediaTime(forHost: t(104)) == nil) // paused
        clock.resume(at: t(108))
        #expect(clock.mediaTime(forHost: t(109)) == t(4)) // 9s wall − 5s paused
        #expect(clock.mediaTime(forHost: t(99)) == nil) // before origin
    }
}
