import CoreGraphics
import Foundation

/// Where everything goes in one output frame. Pure geometry, shared by preview and export.
///
/// Canvas space is the output frame at zoom 1, in output pixels, origin top-left.
/// The camera maps canvas space to output pixels: `pixel = (canvas - viewOrigin) * scale`.
public struct FrameLayout: Equatable, Sendable {
    public struct Camera: Equatable, Sendable {
        public var viewOrigin: CGPoint
        public var scale: Double
        public static let identity = Camera(viewOrigin: .zero, scale: 1)
    }

    public struct Shadow: Equatable, Sendable {
        public var sigma: Double
        public var offsetY: Double
        public var opacity: Double
    }

    /// The cursor sprite as a (possibly rotated) quad on the canvas.
    public struct Cursor: Equatable, Sendable {
        public var sprite: CursorTrack.Sprite
        /// Top-left, top-right, bottom-left, bottom-right, canvas space.
        public var corners: [CGPoint]
        public var opacity: Double
        /// Canvas units per point, for the soft drop shadow.
        public var pointScale: Double
    }

    public struct ClickEffect: Equatable, Sendable {
        public enum Kind: Sendable { case ripple, pulse }
        public var kind: Kind
        public var center: CGPoint
        public var maxRadius: Double
        public var progress: Double
        public var color: RGBAColor
    }

    public var outputSize: CGSize
    /// Where the (cropped) recording sits on the canvas.
    public var screenRect: CGRect
    public var cornerRadius: Double
    public var shadow: Shadow?
    /// Region of the source frame shown in `screenRect`, unit coordinates.
    public var sourceCrop: UnitRect
    public var camera: Camera
    public var background: Background
    public var backgroundNoise: Double
    public var cursor: Cursor?
    public var clickEffects: [ClickEffect] = []

    /// Visible part of the canvas.
    public var visibleCanvasRect: CGRect {
        CGRect(origin: camera.viewOrigin, size: CGSize(width: outputSize.width / camera.scale, height: outputSize.height / camera.scale))
    }

    // MARK: Building

    /// Output aspect for a project (Auto follows the cropped recording).
    public static func outputAspect(for project: Project) -> Double {
        project.canvas.aspect.ratio(source: croppedSourceAspect(project))
    }

    public static func croppedSourceAspect(_ project: Project) -> Double {
        let size = project.recording.pixelSize
        let crop = project.canvas.crop
        let h = Double(size.height) * crop.height
        return h > 0 ? Double(size.width) * crop.width / h : 1
    }

    /// Size-independent reference: style values are authored for a 1080 px short side.
    public static func referenceScale(for size: CGSize) -> Double {
        min(size.width, size.height) / 1080
    }

    /// Full frame: layout, camera (from `camera`, identity if nil) and cursor (if `cursor` is given).
    public static func make(
        project: Project, time: Seconds, outputSize: CGSize,
        cursor track: CursorTrack? = nil, camera: CameraTrack? = nil
    ) -> FrameLayout {
        var layout = base(project: project, outputSize: outputSize)
        // With a device mockup the phone carries the recording: no flat zoom, cursor lives on the screen.
        guard !project.mockup.isEnabled else { return layout }
        if let camera { layout.camera = camera.camera(at: time, outputSize: outputSize) }
        if let track {
            layout.placeCursor(track: track, time: time, toCanvas: layout.mapping(targetSize: track.targetSize), settings: project.cursor)
        }
        return layout
    }

    /// Static layout (no camera motion, no cursor).
    public static func base(project: Project, outputSize: CGSize) -> FrameLayout {
        let canvas = project.canvas
        let ref = referenceScale(for: outputSize)
        let inset = min(outputSize.width, outputSize.height) * canvas.padding
        let available = CGRect(origin: .zero, size: outputSize).insetBy(dx: inset, dy: inset)
        let screen = fit(aspect: croppedSourceAspect(project), in: available)
        let radius = min(canvas.cornerRadius * ref, min(screen.width, screen.height) / 2)
        let shadow = canvas.shadow.enabled && canvas.shadow.opacity > 0
            ? Shadow(sigma: max(canvas.shadow.radius * ref / 2, 0.5), offsetY: canvas.shadow.offsetY * ref, opacity: canvas.shadow.opacity)
            : nil

        return FrameLayout(
            outputSize: outputSize, screenRect: screen, cornerRadius: radius, shadow: shadow,
            sourceCrop: canvas.crop, camera: .identity, background: canvas.background,
            backgroundNoise: canvas.backgroundNoise
        )
    }

    /// Target points → canvas, through the crop.
    func mapping(targetSize: CGSize) -> (CGPoint) -> CGPoint {
        let screen = screenRect, crop = sourceCrop
        return { p in
            let u = CGPoint(x: p.x / max(targetSize.width, 1), y: p.y / max(targetSize.height, 1))
            return CGPoint(
                x: screen.minX + (u.x - crop.x) / crop.width * screen.width,
                y: screen.minY + (u.y - crop.y) / crop.height * screen.height
            )
        }
    }

    mutating func placeCursor(track: CursorTrack, time: Seconds, toCanvas: (CGPoint) -> CGPoint, settings: CursorSettings) {
        let unitsPerPoint = screenRect.width / max(track.targetSize.width * sourceCrop.width, 1)

        clickEffects = track.activeClicks(at: time).map { click, progress in
            ClickEffect(
                kind: settings.clickEffect == .pulse ? .pulse : .ripple,
                center: toCanvas(track.displayedPosition(at: click.time) ?? click.position),
                maxRadius: 22 * settings.scale * unitsPerPoint,
                progress: progress, color: settings.clickEffectColor
            )
        }

        guard let state = track.state(at: time), let sprite = state.sprite, state.opacity > 0.001 else { return }
        let hotspot = toCanvas(state.position)
        // Hidden outside the cropped recording.
        guard screenRect.insetBy(dx: -2, dy: -2).contains(hotspot) else { return }

        let s = unitsPerPoint * settings.scale * state.pressScale
        let origin = CGPoint(x: hotspot.x - sprite.hotspot.x * s, y: hotspot.y - sprite.hotspot.y * s)
        let w = sprite.size.width * s, h = sprite.size.height * s
        let c = cos(state.rotation), sn = sin(state.rotation)
        func rotated(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x: p.x - hotspot.x, y: p.y - hotspot.y)
            return CGPoint(x: hotspot.x + d.x * c - d.y * sn, y: hotspot.y + d.x * sn + d.y * c)
        }
        cursor = Cursor(
            sprite: sprite,
            corners: [origin, CGPoint(x: origin.x + w, y: origin.y), CGPoint(x: origin.x, y: origin.y + h), CGPoint(x: origin.x + w, y: origin.y + h)].map(rotated),
            opacity: state.opacity,
            pointScale: unitsPerPoint * settings.scale
        )
    }

    /// Crop editing: the whole uncropped recording, centered, on a plain dark canvas.
    public static func cropEditing(project: Project, outputSize: CGSize) -> FrameLayout {
        FrameLayout(
            outputSize: outputSize,
            screenRect: cropEditingSourceRect(canvasSize: outputSize, sourceAspect: project.recording.pixelSize.aspect),
            cornerRadius: 0, shadow: nil, sourceCrop: .full, camera: .identity,
            background: .color(RGBAColor(hex: 0x0C0C0E)), backgroundNoise: 0
        )
    }

    /// Shared by the renderer and the crop overlay so handles line up with pixels.
    public static func cropEditingSourceRect(canvasSize: CGSize, sourceAspect: Double) -> CGRect {
        let inset = min(canvasSize.width, canvasSize.height) * 0.04
        return fit(aspect: sourceAspect, in: CGRect(origin: .zero, size: canvasSize).insetBy(dx: inset, dy: inset))
    }

    public static func fit(aspect: Double, in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0, aspect > 0 else { return .zero }
        let size = rect.width / rect.height > aspect
            ? CGSize(width: rect.height * aspect, height: rect.height)
            : CGSize(width: rect.width, height: rect.width / aspect)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// Camera motion from zoom segments.
public enum ZoomCamera {
    /// How far a segment is zoomed in at `time` (0 = not at all, 1 = fully), after easing.
    public static func amount(of zoom: ZoomSegment, at time: Seconds) -> Double {
        guard zoom.range.contains(time) else { return 0 }
        let inProgress = zoom.transitionIn > 0 ? (time - zoom.range.start) / zoom.transitionIn : 1
        let outProgress = zoom.transitionOut > 0 ? (zoom.range.end - time) / zoom.transitionOut : 1
        return min(zoom.easing.value(inProgress), zoom.easing.value(outProgress))
    }

    /// The visible canvas rect when fully zoomed: centered on `focus`, kept inside the recording
    /// when it fits (so no background shows), otherwise inside the canvas.
    public static func targetRect(scale: Double, focus: CGPoint, canvas: CGSize, screen: CGRect) -> CGRect {
        let size = CGSize(width: canvas.width / scale, height: canvas.height / scale)
        func clampAxis(_ center: Double, _ length: Double, screenMin: Double, screenMax: Double, canvasLength: Double) -> Double {
            let origin = center - length / 2
            if length <= screenMax - screenMin {
                return min(max(origin, screenMin), screenMax - length)
            }
            // Wider than the recording: center on it, but never past the canvas edges.
            let centered = (screenMin + screenMax) / 2 - length / 2
            return min(max(centered, 0), canvasLength - length)
        }
        return CGRect(
            x: clampAxis(focus.x, size.width, screenMin: screen.minX, screenMax: screen.maxX, canvasLength: canvas.width),
            y: clampAxis(focus.y, size.height, screenMin: screen.minY, screenMax: screen.maxY, canvasLength: canvas.height),
            width: size.width, height: size.height
        )
    }

    /// Moves from rect `a` to rect `b` (same aspect) about their common fixed point, with geometric
    /// size interpolation so zoom speed feels constant. Pure pans (equal sizes) are linear.
    public static func interpolate(from a: CGRect, to b: CGRect, amount t: Double) -> CGRect {
        let w0 = a.width, w1 = b.width
        guard w0 > 0, w1 > 0 else { return b }
        let width = w0 * pow(w1 / w0, t)
        let ratio = width / w0
        let aspect = a.height / a.width
        if abs(w0 - w1) < 1e-6 * w0 {
            return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t, width: width, height: width * aspect)
        }
        // Fixed point f satisfies (f - a.origin) / w0 == (f - b.origin) / w1.
        let fx = (b.minX * w0 - a.minX * w1) / (w0 - w1)
        let fy = (b.minY * w0 - a.minY * w1) / (w0 - w1)
        return CGRect(x: fx - (fx - a.minX) * ratio, y: fy - (fy - a.minY) * ratio, width: width, height: width * aspect)
    }

    /// Camera showing `rect` (canvas space) on an output of `outputSize`.
    public static func camera(showing rect: CGRect, outputSize: CGSize) -> FrameLayout.Camera {
        FrameLayout.Camera(viewOrigin: rect.origin, scale: outputSize.width / max(rect.width, 1e-9))
    }
}
