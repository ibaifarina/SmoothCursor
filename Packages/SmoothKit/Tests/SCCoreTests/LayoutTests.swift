import CoreGraphics
import Testing
@testable import SCCore

@Suite struct EasingTests {
    @Test func endpointsAndMonotonicBezier() {
        for easing in [Easing.linear, .easeIn, .easeOut, .easeInOut, .default] {
            #expect(abs(easing.value(0)) < 1e-6)
            #expect(abs(easing.value(1) - 1) < 1e-6)
            var last = -1.0
            for i in 0...50 {
                let v = easing.value(Double(i) / 50)
                #expect(v >= last - 1e-9)
                last = v
            }
        }
        #expect(abs(Easing.easeInOut.value(0.5) - 0.5) < 1e-4) // symmetric curve
    }

    @Test func springsSettleWithinTheirDuration() {
        for spring in [SpringParams.smooth, .snappy, .gentle, .bouncy] {
            #expect(abs(spring.normalizedResponse(0.999) - 1) < 0.01)
            #expect(spring.normalizedResponse(0) == 0)
        }
        // Underdamped springs overshoot.
        let peak = (1...100).map { SpringParams.bouncy.normalizedResponse(Double($0) / 100) }.max()!
        #expect(peak > 1.05)
    }
}

@Suite struct LayoutTests {
    func project(width: Int = 1920, height: Int = 1080) -> Project {
        Project(name: "T", recording: RecordingInfo(
            sourceKind: .display, videoFile: "v.mov", pixelSize: PixelSize(width: width, height: height),
            displayScale: 2, fps: 60, duration: 10
        ))
    }

    @Test func paddingAndAspectFit() {
        var p = project()
        p.canvas.padding = 0.1
        p.canvas.aspect = .square
        let l = FrameLayout.make(project: p, time: 0, outputSize: CGSize(width: 1000, height: 1000))
        // 100 px padding each side, 16:9 recording fitted into 800×800.
        #expect(abs(l.screenRect.width - 800) < 0.01)
        #expect(abs(l.screenRect.height - 450) < 0.01)
        #expect(abs(l.screenRect.midY - 500) < 0.01)
        #expect(l.camera == .identity)
    }

    @Test func cropChangesAspect() {
        var p = project()
        p.canvas.crop = UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(abs(FrameLayout.croppedSourceAspect(p) - (960.0 / 1080)) < 1e-9)
        #expect(abs(FrameLayout.outputAspect(for: p) - (960.0 / 1080)) < 1e-9)
    }

    @Test func fullZoomStaysInsideRecording() {
        var p = project()
        p.canvas.padding = 0.1
        p.zooms = [ZoomSegment(range: TimeRange(start: 0, end: 4), scale: 2, focus: .fixed(UnitPoint2D(x: 0, y: 0)))]
        let size = CGSize(width: 1920, height: 1080)
        let l = FrameLayout.make(project: p, time: 2, outputSize: size, camera: CameraTrack(project: p, cursor: nil))
        let visible = l.visibleCanvasRect
        #expect(abs(l.camera.scale - 2) < 1e-6)
        // Focus at the top-left corner clamps to the recording's corner: no background visible.
        #expect(abs(visible.minX - l.screenRect.minX) < 1e-6)
        #expect(abs(visible.minY - l.screenRect.minY) < 1e-6)
    }

    @Test func zoomEasesInAndOut() {
        var p = project()
        p.zooms = [ZoomSegment(range: TimeRange(start: 1, end: 3), scale: 2, transitionIn: 0.5, transitionOut: 0.5)]
        let size = CGSize(width: 1920, height: 1080)
        let track = CameraTrack(project: p, cursor: nil)
        let scales = stride(from: 0.9, through: 3.1, by: 0.05).map { FrameLayout.make(project: p, time: $0, outputSize: size, camera: track).camera.scale }
        #expect(abs(scales.first! - 1) < 1e-9)
        #expect(abs(scales.last! - 1) < 1e-9)
        #expect(abs(scales.max()! - 2) < 1e-3)
        // Monotonic in, then out.
        let peak = scales.firstIndex { abs($0 - 2) < 1e-3 }!
        #expect(zip(scales[..<peak], scales[1...peak]).allSatisfy { $0 <= $1 + 1e-9 })
    }

    @Test func interpolationKeepsFixedPoint() {
        let full = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let target = CGRect(x: 600, y: 250, width: 250, height: 125)
        let end = ZoomCamera.interpolate(from: full, to: target, amount: 1)
        #expect(abs(end.width - 250) < 1e-9 && abs(end.minX - 600) < 1e-6 && abs(end.minY - 250) < 1e-6)
        let start = ZoomCamera.interpolate(from: full, to: target, amount: 0)
        #expect(abs(start.width - 1000) < 1e-9 && abs(start.minX) < 1e-9)
        // The fixed point maps to the same relative position at every step.
        let mid = ZoomCamera.interpolate(from: full, to: target, amount: 0.5)
        let fx = (target.minX * 1000 - 0 * 250) / (1000 - 250)
        #expect(abs((fx - mid.minX) / mid.width - fx / 1000) < 1e-9)
    }
}

@Suite struct CropTests {
    func inside(_ r: UnitRect) -> Bool {
        r.x >= -1e-9 && r.y >= -1e-9 && r.x + r.width <= 1 + 1e-9 && r.y + r.height <= 1 + 1e-9
    }

    @Test func freeResizeClampsAndKeepsMinimum() {
        let r = CropGeometry.apply(.topLeft, to: .full, delta: CGSize(width: 2, height: 2), unitRatio: nil)
        #expect(abs(r.width - CropGeometry.minSize) < 1e-9 && abs(r.height - CropGeometry.minSize) < 1e-9)
        let moved = CropGeometry.apply(.move, to: UnitRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5), delta: CGSize(width: 1, height: -1), unitRatio: nil)
        #expect(moved == UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    @Test func lockedRatioHoldsForEveryHandleAndStaysInside() {
        let ratio = 0.75
        let start = UnitRect(x: 0.3, y: 0.3, width: 0.3, height: 0.4)
        for handle in CropGeometry.Handle.resizers {
            for d in [CGSize(width: 0.5, height: 0.4), CGSize(width: -0.5, height: -0.4), CGSize(width: 0.05, height: -0.02)] {
                let r = CropGeometry.apply(handle, to: start, delta: d, unitRatio: ratio)
                #expect(abs(r.width / r.height - ratio) < 1e-6, "\(handle) \(d)")
                #expect(inside(r), "\(handle) \(d) → \(r)")
            }
        }
    }

    @Test func conformCentersLargestRect() {
        let r = CropGeometry.conform(.full, unitRatio: 0.5)
        #expect(abs(r.height - 1) < 1e-9 && abs(r.width - 0.5) < 1e-9 && abs(r.x - 0.25) < 1e-9)
    }
}
