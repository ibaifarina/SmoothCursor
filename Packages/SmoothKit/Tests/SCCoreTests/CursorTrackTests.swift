import CoreGraphics
import Foundation
import Testing
@testable import SCCore

@Suite struct CursorTrackTests {
    let sprite = CursorTrack.Sprite(imageURL: URL(fileURLWithPath: "/tmp/c.png"), hotspot: .zero, size: CGSize(width: 10, height: 10))

    /// Cursor moving right at 400 pt/s for 1 s, a click at 1.2 s, then idle until 6 s.
    func telemetry() -> Telemetry {
        var events: [Telemetry.Event] = []
        for i in 0...120 {
            let t = Double(i) / 120
            events.append(.init(time: t, kind: .move, x: Float(100 + 400 * t), y: 300))
        }
        events.append(.init(time: 1.2, kind: .mouseDown, x: 500, y: 300))
        events.append(.init(time: 1.3, kind: .mouseUp, x: 500, y: 300))
        return Telemetry(header: .init(targetSize: PixelSize(width: 1000, height: 600), displayScale: 2), events: events)
    }

    func track(_ configure: (inout CursorSettings) -> Void = { _ in }) -> CursorTrack {
        var s = CursorSettings()
        configure(&s)
        return CursorTrack(telemetry: telemetry(), settings: s, sprites: [sprite], duration: 6)
    }

    @Test func smoothedCursorDoesNotTrailBehind() {
        let t = track()
        // Mid-motion, the lookahead keeps the smoothed cursor within a few points of the real one.
        let p = t.displayedPosition(at: 0.6)!
        #expect(abs(p.x - 340) < 25, "x = \(p.x)")
        #expect(abs(p.y - 300) < 1)
    }

    @Test func cursorSitsExactlyOnClicks() {
        let p = track().displayedPosition(at: 1.2)!
        #expect(abs(p.x - 500) < 0.5 && abs(p.y - 300) < 0.5)
    }

    @Test func hidesWhenIdleAndReturnsBeforeMoving() {
        let t = track { $0.idleDelay = 2 }
        #expect(t.state(at: 1.5)!.opacity == 1)
        #expect(t.state(at: 5.0)!.opacity == 0) // idle since 1.3 s
        let never = track { $0.hideWhenIdle = false }
        #expect(never.state(at: 5.0)!.opacity == 1)
    }

    @Test func rawModeFollowsTelemetryExactly() {
        let p = track { $0.smoothingAmount = 0 }.displayedPosition(at: 0.5)!
        #expect(abs(p.x - 300) < 0.01)
    }

    @Test func pressShrinksCursor() {
        let t = track { $0.clickEffect = .press }
        #expect(t.state(at: 1.25)!.pressScale < 0.9)
        #expect(t.state(at: 2.0)!.pressScale == 1)
    }

    @Test func rippleIsActiveRightAfterClick() {
        let t = track { $0.clickEffect = .ripple }
        #expect(t.activeClicks(at: 1.3).count == 1)
        #expect(t.activeClicks(at: 2.5).isEmpty)
    }
}
