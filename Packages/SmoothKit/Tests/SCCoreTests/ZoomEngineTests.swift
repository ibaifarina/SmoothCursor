import CoreGraphics
import Foundation
import Testing
@testable import SCCore

@Suite struct CameraTrackTests {
    func project(duration: Double = 12) -> Project {
        var p = Project(name: "T", recording: RecordingInfo(
            sourceKind: .display, videoFile: "v.mov", pixelSize: PixelSize(width: 2000, height: 1000),
            displayScale: 2, fps: 60, duration: duration
        ))
        p.canvas.padding = 0
        return p
    }

    /// Cursor parked at (200, 200) until 4 s, then jumps to (1700, 800) (target is 1000×500 pt).
    func cursor(duration: Double = 12) -> CursorTrack {
        var events: [Telemetry.Event] = [.init(time: 0, kind: .move, x: 100, y: 100)]
        events.append(.init(time: 4, kind: .move, x: 850, y: 400))
        let t = Telemetry(header: .init(targetSize: PixelSize(width: 1000, height: 500), displayScale: 2), events: events)
        var s = CursorSettings()
        s.smoothingAmount = 0
        return CursorTrack(telemetry: t, settings: s,
                           sprites: [.init(imageURL: URL(fileURLWithPath: "/c.png"), hotspot: .zero, size: CGSize(width: 10, height: 10))],
                           duration: duration)
    }

    @Test func adjacentZoomsPanWithoutZoomingOut() {
        var p = project()
        p.zooms = [
            ZoomSegment(range: TimeRange(start: 1, end: 4), scale: 2, focus: .fixed(UnitPoint2D(x: 0.25, y: 0.5))),
            ZoomSegment(range: TimeRange(start: 4.5, end: 8), scale: 2, focus: .fixed(UnitPoint2D(x: 0.75, y: 0.5))),
        ]
        let track = CameraTrack(project: p, cursor: nil)
        // Throughout the handoff the view stays well zoomed in (never back to the full canvas).
        let widths = stride(from: 3.5, through: 5.0, by: 0.05).map { track.visibleUnitRect(at: $0).width }
        #expect(widths.max()! < 0.75, "max width \(widths.max()!)")
        // And it really moved from the left half to the right half.
        #expect(track.visibleUnitRect(at: 3).midX < 0.4)
        #expect(track.visibleUnitRect(at: 6).midX > 0.6)
    }

    @Test func distantZoomsZoomOutInBetween() {
        var p = project()
        p.zooms = [
            ZoomSegment(range: TimeRange(start: 1, end: 3), scale: 2),
            ZoomSegment(range: TimeRange(start: 6, end: 8), scale: 2),
        ]
        let track = CameraTrack(project: p, cursor: nil)
        #expect(abs(track.visibleUnitRect(at: 4.5).width - 1) < 1e-9)
    }

    @Test func followKeepsCursorInsideViewAndIgnoresSmallMoves() {
        var p = project()
        p.zooms = [ZoomSegment(range: TimeRange(start: 1, end: 10), scale: 2.5, focus: .followCursor(deadZone: 0.2), transitionIn: 0.5)]
        let track = CameraTrack(project: p, cursor: cursor())
        let before = track.visibleUnitRect(at: 3)
        // Cursor at (100,100) pt → (0.1, 0.2) of the canvas; it must be in view.
        #expect(before.contains(CGPoint(x: 0.1, y: 0.2)))
        // Well after the jump to (0.85, 0.8), the camera has followed.
        let after = track.visibleUnitRect(at: 7)
        #expect(after.contains(CGPoint(x: 0.85, y: 0.8)), "\(after)")
        // Never shows anything outside the recording at full zoom.
        #expect(after.minX >= -1e-6 && after.maxX <= 1 + 1e-6 && after.minY >= -1e-6 && after.maxY <= 1 + 1e-6)
    }
}

@Suite struct AutoZoomTests {
    func telemetry(_ events: [Telemetry.Event]) -> Telemetry {
        Telemetry(header: .init(targetSize: PixelSize(width: 1440, height: 900), displayScale: 2), events: events)
    }

    func click(_ t: Double, _ x: Float = 400, _ y: Float = 300) -> [Telemetry.Event] {
        [.init(time: t, kind: .mouseDown, x: x, y: y), .init(time: t + 0.08, kind: .mouseUp, x: x, y: y)]
    }

    @Test func closeClicksMergeAndFarClicksSplit() {
        let t = telemetry(click(2) + click(3) + click(4.2) + click(15))
        let zooms = AutoZoom.segments(telemetry: t, duration: 20, settings: AutoZoomSettings())
        #expect(zooms.count == 2)
        #expect(zooms[0].range.start < 2 && zooms[0].range.end > 4.2) // zoomed in before the first click
        #expect(zooms.allSatisfy { $0.origin == .auto })
    }

    @Test func typingBurstZoomsOnTheClickedField() {
        var events = click(1, 700, 450)
        for i in 0..<8 { events.append(.init(time: 6 + Double(i) * 0.15, kind: .keyDown, x: 0, y: 0, code: 0)) }
        let zooms = AutoZoom.segments(telemetry: telemetry(events), duration: 12, settings: AutoZoomSettings())
        #expect(zooms.contains { $0.range.contains(6.5) })
    }

    @Test func lowSensitivityIgnoresASingleClick() {
        var settings = AutoZoomSettings()
        settings.sensitivity = 0.1
        #expect(AutoZoom.segments(telemetry: telemetry(click(3)), duration: 10, settings: settings).isEmpty)
        settings.sensitivity = 0.5
        #expect(AutoZoom.segments(telemetry: telemetry(click(3)), duration: 10, settings: settings).count == 1)
    }

    @Test func spreadOutActionLowersZoom() {
        let t = telemetry(click(2, 100, 100) + click(2.8, 1300, 800))
        let zoom = AutoZoom.segments(telemetry: t, duration: 10, settings: AutoZoomSettings()).first!
        #expect(zoom.scale < 1.6)
    }

    @Test func regenerateKeepsManualZooms() {
        var p = Project(name: "T", recording: RecordingInfo(
            sourceKind: .display, videoFile: "v.mov", pixelSize: PixelSize(width: 2880, height: 1800), displayScale: 2, fps: 60, duration: 20
        ))
        let manual = ZoomSegment(range: TimeRange(start: 1, end: 3), scale: 3, origin: .manual)
        p.zooms = [manual]
        AutoZoom.regenerate(&p, telemetry: telemetry(click(2) + click(10)))
        #expect(p.zooms.contains(manual))
        #expect(p.zooms.filter { $0.origin == .auto }.count == 1) // the one overlapping the manual zoom is dropped
        #expect(p.autoZoomGenerated)
    }
}
