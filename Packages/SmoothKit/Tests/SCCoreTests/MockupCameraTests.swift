import CoreGraphics
import Testing
@testable import SCCore

@Suite struct MockupCameraTests {
    let half = CGSize(width: 0.44, height: 0.94)

    @Test func noClipsMeansFront() {
        #expect(MockupCamera.camera(at: 3, clips: [], screenHalf: half) == .front)
    }

    @Test func shotsBlendContinuously() {
        let clips = [
            CameraClip(range: TimeRange(start: 0, end: 4), preset: .hero, transition: 1),
            CameraClip(range: TimeRange(start: 4, end: 8), preset: .orbitLeft, transition: 1),
        ]
        // No jumps: consecutive samples stay close everywhere, including across the handoff.
        var last = MockupCamera.camera(at: 0, clips: clips, screenHalf: half)
        for i in 1...800 {
            let c = MockupCamera.camera(at: Double(i) / 100, clips: clips, screenHalf: half)
            #expect(abs(c.yaw - last.yaw) < 0.05 && abs(c.pitch - last.pitch) < 0.05 && abs(c.distance - last.distance) < 0.05, "jump at \(Double(i) / 100)")
            last = c
        }
    }

    @Test func gapsRestOnFront() {
        let clips = [CameraClip(range: TimeRange(start: 1, end: 3), preset: .hero, transition: 0.8),
                     CameraClip(range: TimeRange(start: 7, end: 9), preset: .tiltUp, transition: 0.8)]
        #expect(MockupCamera.camera(at: 5, clips: clips, screenHalf: half) == .front)
        #expect(MockupCamera.camera(at: 2, clips: clips, screenHalf: half).yaw < -0.3)
    }

    @Test func autoShotsCoverTheRecordingWithCloseUpsOnZooms() {
        let zooms = [ZoomSegment(range: TimeRange(start: 5, end: 8), focus: .fixed(UnitPoint2D(x: 0.2, y: 0.8)))]
        let shots = MockupCamera.autoShots(duration: 20, zooms: zooms)
        #expect(shots.first?.range.start == 0)
        #expect(abs((shots.last?.range.end ?? 0) - 20) < 1e-9)
        let close = shots.first { $0.preset == .closeUp }
        #expect(close?.range == TimeRange(start: 5, end: 8))
        #expect(close?.focus == UnitPoint2D(x: 0.2, y: 0.8))
        // Contiguous: every shot starts where the previous ended.
        #expect(zip(shots, shots.dropFirst()).allSatisfy { abs($0.range.end - $1.range.start) < 1e-9 })
    }
}

@Suite struct AutoShotRulesTests {
    @Test func weakZoomsStayWideAndNoShotIsTiny() {
        let zooms = [
            ZoomSegment(range: TimeRange(start: 0.6, end: 9.2), scale: 1.3),
            ZoomSegment(range: TimeRange(start: 10.8, end: 15.1), scale: 2),
            ZoomSegment(range: TimeRange(start: 16.2, end: 20.2), scale: 1.3),
        ]
        let shots = MockupCamera.autoShots(duration: 20.2, zooms: zooms)
        #expect(shots.allSatisfy { $0.range.duration >= 1.5 - 1e-9 })
        #expect(shots.filter { $0.preset == .closeUp }.count == 1)
        #expect(Set(shots.map(\.preset)).count >= 3) // varied
        #expect(abs(shots.last!.range.end - 20.2) < 1e-9 && shots.first!.range.start == 0)
    }
}
