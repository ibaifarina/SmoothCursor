import CoreGraphics
import Foundation
import Testing
@testable import SCCore

@Suite struct MotionBlurTests {
    func project() -> Project {
        var p = Project(name: "T", recording: RecordingInfo(
            sourceKind: .display, videoFile: "v", pixelSize: PixelSize(width: 2000, height: 1000), displayScale: 2, fps: 60, duration: 10
        ))
        p.motionBlur.enabled = true
        p.motionBlur.amount = 0.5
        p.cursor.smoothingAmount = 0
        return p
    }

    func cursor(_ p: Project, events: [Telemetry.Event]) -> CursorTrack {
        let t = Telemetry(header: .init(targetSize: PixelSize(width: 1000, height: 500), displayScale: 2), events: events)
        return CursorTrack(telemetry: t, settings: p.cursor,
                           sprites: [.init(imageURL: URL(fileURLWithPath: "/c.png"), hotspot: .zero, size: CGSize(width: 10, height: 10))],
                           duration: 10)
    }

    let size = CGSize(width: 1920, height: 960)

    @Test func staticFrameNeedsNoBlur() {
        let p = project()
        let c = cursor(p, events: [.init(time: 0, kind: .move, x: 100, y: 100)])
        #expect(FrameLayout.motionBlur(project: p, time: 2, outputSize: size, cursor: c, camera: nil, frameDuration: 1 / 60, quality: .export) == nil)
    }

    @Test func zoomTransitionBlursCamera() {
        var p = project()
        p.zooms = [ZoomSegment(range: TimeRange(start: 1, end: 4), scale: 2.5, focus: .fixed(.center))]
        let m = FrameLayout.motionBlur(project: p, time: 1.35, outputSize: size, cursor: nil, camera: CameraTrack(project: p, cursor: nil),
                                       frameDuration: 1 / 60, quality: .export)
        #expect(m?.hasCameraMotion == true)
    }

    @Test func movingCursorIsSampledButTeleportsStaySharp() {
        let p = project()
        var moving: [Telemetry.Event] = []
        for i in 0...120 { moving.append(.init(time: Double(i) / 120, kind: .move, x: Float(100 + 600 * Double(i) / 120), y: 200)) }
        let m = FrameLayout.motionBlur(project: p, time: 0.5, outputSize: size, cursor: cursor(p, events: moving), camera: nil, frameDuration: 1 / 60, quality: .export)
        #expect((m?.cursors.count ?? 0) >= 8)

        let jump: [Telemetry.Event] = [.init(time: 0, kind: .move, x: 50, y: 50), .init(time: 0.5, kind: .move, x: 950, y: 450)]
        let t = FrameLayout.motionBlur(project: p, time: 0.5, outputSize: size, cursor: cursor(p, events: jump), camera: nil, frameDuration: 1 / 60, quality: .export)
        #expect(t == nil || t!.cursors.isEmpty)
    }

    @Test func disabledMeansNothing() {
        var p = project()
        p.motionBlur.enabled = false
        p.zooms = [ZoomSegment(range: TimeRange(start: 1, end: 4), scale: 2.5)]
        #expect(FrameLayout.motionBlur(project: p, time: 1.35, outputSize: size, cursor: nil, camera: CameraTrack(project: p, cursor: nil), frameDuration: 1 / 60, quality: .export) == nil)
    }
}

extension MotionBlurFrame: Equatable {
    public static func == (a: MotionBlurFrame, b: MotionBlurFrame) -> Bool {
        a.cameraFrom == b.cameraFrom && a.cameraTo == b.cameraTo && a.cursors == b.cursors && a.taps == b.taps
    }
}
