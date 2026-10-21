import CoreGraphics
import Foundation

/// What the renderer needs to blur one frame: the camera at both ends of the shutter interval
/// and the cursor at several instants inside it.
public struct MotionBlurFrame: Sendable {
    public var cameraFrom: FrameLayout.Camera
    public var cameraTo: FrameLayout.Camera
    /// Empty when the cursor doesn't move noticeably (it is drawn once, sharp).
    public var cursors: [FrameLayout.Cursor]
    /// Samples along each pixel's motion path in the camera blur pass.
    public var taps: Int

    public var hasCameraMotion: Bool { cameraFrom != cameraTo }
}

public enum MotionBlurQuality: Sendable {
    case preview, export

    var taps: Int { self == .preview ? 16 : 48 }
    /// Cursor samples: enough for ~1.5 px spacing along its path, within these bounds.
    var cursorSampleRange: ClosedRange<Int> { self == .preview ? 4...24 : 8...64 }
}

extension FrameLayout {
    /// Motion blur inputs for the frame at `time`, or nil when blur is off or nothing moves.
    /// `frameDuration` is one output frame (1 / export fps); the shutter covers `amount` of it.
    public static func motionBlur(
        project: Project, time: Seconds, outputSize: CGSize,
        cursor: CursorTrack?, camera: CameraTrack?, frameDuration: Seconds, quality: MotionBlurQuality
    ) -> MotionBlurFrame? {
        let settings = project.motionBlur
        guard settings.enabled, settings.amount > 0.001, !project.mockup.isEnabled else { return nil }
        let shutter = settings.amount * frameDuration
        let a = time - shutter / 2, b = time + shutter / 2

        var from = FrameLayout.Camera.identity, to = FrameLayout.Camera.identity
        if let camera {
            let now = camera.camera(at: time, outputSize: outputSize)
            from = settings.applyToCamera ? camera.camera(at: a, outputSize: outputSize) : now
            to = settings.applyToCamera ? camera.camera(at: b, outputSize: outputSize) : now
        }

        var cursors: [FrameLayout.Cursor] = []
        if settings.applyToCursor, let cursor {
            let now = camera?.camera(at: time, outputSize: outputSize) ?? .identity
            func screenPosition(_ t: Seconds) -> CGPoint? {
                let l = FrameLayout.make(project: project, time: t, outputSize: outputSize, cursor: cursor, camera: camera)
                guard let c = l.cursor?.corners.first else { return nil }
                return CGPoint(x: (c.x - l.camera.viewOrigin.x) * l.camera.scale, y: (c.y - l.camera.viewOrigin.y) * l.camera.scale)
            }
            let travel: Double = if let p = screenPosition(a), let q = screenPosition(b) { hypot(q.x - p.x, q.y - p.y) } else { 0 }
            // A jump across a big part of the frame in one shutter is a teleport, not motion: keep it sharp.
            let teleport = travel > 0.2 * max(outputSize.width, outputSize.height)
            let range = quality.cursorSampleRange
            let n = teleport || travel < 0.75 ? 0 : min(max(Int(travel / 1.5), range.lowerBound), range.upperBound)
            cursors = (0..<n).compactMap { i in
                let t = a + shutter * Double(i) / Double(n - 1)
                let sample = FrameLayout.make(project: project, time: t, outputSize: outputSize, cursor: cursor, camera: camera)
                guard var c = sample.cursor else { return nil }
                // Where this instant's cursor lands on screen, expressed in the current camera's canvas.
                let k = sample.camera.scale / now.scale
                c.corners = c.corners.map { p in
                    CGPoint(x: now.viewOrigin.x + (p.x - sample.camera.viewOrigin.x) * k,
                            y: now.viewOrigin.y + (p.y - sample.camera.viewOrigin.y) * k)
                }
                return c
            }
            // Hidden for part of the shutter (fading in/out of view): draw it once.
            if cursors.count < n { cursors = [] }
        }

        let frame = MotionBlurFrame(cameraFrom: from, cameraTo: to, cursors: cursors, taps: quality.taps)
        return frame.hasCameraMotion || !frame.cursors.isEmpty ? frame : nil
    }
}
