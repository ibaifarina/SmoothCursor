import CoreGraphics
import Foundation

/// Dimensions of a modern edge-to-edge phone in millimetres, built around the recording's aspect.
/// Model space: x right, y up, z toward the viewer; the screen faces +z. Always portrait —
/// landscape recordings rotate the model instead.
public struct PhoneGeometry: Equatable, Sendable {
    public let screen: CGSize
    public let screenRadius: Double
    public let body: CGSize
    public let bodyRadius: Double
    public let thickness: Double
    public let edgeRadius: Double
    public let islandCenterY: Double
    public let islandSize: CGSize
    public let plateauCenter: CGPoint
    public let plateauSize: Double

    /// `aspect` = width ÷ height of the portrait screen (≤ 1).
    public init(portraitAspect aspect: Double) {
        let w = 64.0
        let h = w / min(max(aspect, 0.3), 1)
        screen = CGSize(width: w, height: h)
        let border = 1.9 + 0.75 // black bezel + metal lip
        body = CGSize(width: w + 2 * border, height: h + 2 * border)
        bodyRadius = body.width * 0.165
        screenRadius = bodyRadius - border
        thickness = 8.3
        edgeRadius = 1.3
        islandSize = CGSize(width: w * 0.31, height: w * 0.092)
        islandCenterY = h / 2 - h * 0.041
        plateauSize = body.width * 0.43
        let margin = body.width * 0.055
        plateauCenter = CGPoint(x: body.width / 2 - margin - plateauSize / 2, y: body.height / 2 - margin - plateauSize / 2)
    }

    /// Screen half size in phone half-heights, as seen in the world (landscape phones lie on their side).
    public func screenHalf(landscape: Bool) -> CGSize {
        landscape
            ? CGSize(width: screen.height / body.width, height: screen.width / body.width)
            : CGSize(width: screen.width / body.height, height: screen.height / body.height)
    }

    /// World half extents (x, y) of the body.
    public func worldHalf(landscape: Bool) -> CGSize {
        landscape ? CGSize(width: body.height / 2, height: body.width / 2) : CGSize(width: body.width / 2, height: body.height / 2)
    }
}

/// Everything the renderer needs for a mockup frame.
public struct MockupFrame: Sendable {
    public var settings: MockupSettings
    public var geometry: PhoneGeometry
    public var landscape: Bool
    /// One camera for a sharp frame; several spread over the shutter for motion blur.
    public var cameras: [Camera3D]
    /// What the phone screen shows (recording + cursor), as a flat layout.
    public var screen: FrameLayout
    /// Canvas padding, so the phone keeps the same breathing room as flat recordings.
    public var padding: Double
}

extension FrameLayout {
    /// The mockup for `time`, or nil when mockups are off.
    public static func mockup(
        project: Project, time: Seconds, cursor: CursorTrack?, frameDuration: Seconds, quality: MotionBlurQuality
    ) -> MockupFrame? {
        guard project.mockup.isEnabled else { return nil }
        let aspect = croppedSourceAspect(project)
        let landscape = aspect > 1
        let geometry = PhoneGeometry(portraitAspect: landscape ? 1 / aspect : aspect)
        let half = geometry.screenHalf(landscape: landscape)

        // Screen content at the recording's own resolution (capped), so close-ups stay sharp.
        let crop = project.canvas.crop
        let w = Double(project.recording.pixelSize.width) * crop.width, h = Double(project.recording.pixelSize.height) * crop.height
        let scale = min(2048 / max(w, h), 1)
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        var screen = FrameLayout(
            outputSize: size, screenRect: CGRect(origin: .zero, size: size), cornerRadius: 0, shadow: nil,
            sourceCrop: crop, camera: .identity, background: .color(.black), backgroundNoise: 0
        )
        if let cursor {
            screen.placeCursor(track: cursor, time: time, toCanvas: screen.mapping(targetSize: cursor.targetSize), settings: project.cursor)
        }

        var cameras = [MockupCamera.camera(at: time, clips: project.cameraClips, screenHalf: half)]
        if project.motionBlur.enabled, project.motionBlur.applyToCamera, quality == .export {
            let shutter = project.motionBlur.amount * frameDuration
            let n = 8
            let samples = (0..<n).map { i in
                MockupCamera.camera(at: time - shutter / 2 + shutter * Double(i) / Double(n - 1), clips: project.cameraClips, screenHalf: half)
            }
            let moving = zip(samples, samples.dropFirst()).contains { a, b in
                let angles: Double = abs(a.yaw - b.yaw) + abs(a.pitch - b.pitch) + abs(a.roll - b.roll)
                let dolly: Double = abs(log(a.distance / b.distance))
                return angles + dolly > 1e-4
            }
            if moving { cameras = samples }
        }
        return MockupFrame(settings: project.mockup, geometry: geometry, landscape: landscape, cameras: cameras, screen: screen, padding: project.canvas.padding)
    }
}
