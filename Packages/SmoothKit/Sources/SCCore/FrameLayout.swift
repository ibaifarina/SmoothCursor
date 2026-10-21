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

    public static func make(project: Project, time: Seconds, outputSize: CGSize, cursor: CGPoint? = nil) -> FrameLayout {
        let canvas = project.canvas
        let ref = referenceScale(for: outputSize)
        let inset = min(outputSize.width, outputSize.height) * canvas.padding
        let available = CGRect(origin: .zero, size: outputSize).insetBy(dx: inset, dy: inset)
        let screen = fit(aspect: croppedSourceAspect(project), in: available)
        let radius = min(canvas.cornerRadius * ref, min(screen.width, screen.height) / 2)
        let shadow = canvas.shadow.enabled && canvas.shadow.opacity > 0
            ? Shadow(sigma: max(canvas.shadow.radius * ref / 2, 0.5), offsetY: canvas.shadow.offsetY * ref, opacity: canvas.shadow.opacity)
            : nil

        var layout = FrameLayout(
            outputSize: outputSize, screenRect: screen, cornerRadius: radius, shadow: shadow,
            sourceCrop: canvas.crop, camera: .identity, background: canvas.background,
            backgroundNoise: canvas.backgroundNoise
        )
        layout.camera = ZoomCamera.camera(for: project, time: time, layout: layout, cursor: cursor)
        return layout
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

    static func camera(for project: Project, time: Seconds, layout: FrameLayout, cursor: CGPoint?) -> FrameLayout.Camera {
        // Strongest active zoom wins; smooth zoom-to-zoom handoffs come with the zoom engine (step 5).
        guard let (zoom, amount) = project.zooms
            .map({ ($0, amount(of: $0, at: time)) })
            .max(by: { $0.1 < $1.1 }),
            amount > 0.0001, zoom.scale > 1.0001
        else { return .identity }

        let screen = layout.screenRect
        let focus: CGPoint = switch zoom.focus {
        case let .fixed(point):
            // Focus is in source units; map through the crop onto the screen rect.
            CGPoint(
                x: screen.minX + (point.x - layout.sourceCrop.x) / layout.sourceCrop.width * screen.width,
                y: screen.minY + (point.y - layout.sourceCrop.y) / layout.sourceCrop.height * screen.height
            )
        case .followCursor:
            cursor ?? CGPoint(x: screen.midX, y: screen.midY)
        }
        let target = targetRect(scale: zoom.scale, focus: focus, canvas: layout.outputSize, screen: screen)
        return interpolate(to: target, canvas: layout.outputSize, amount: amount)
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

    /// Zooms from the full canvas towards `target` about their common fixed point, with
    /// geometric size interpolation so the zoom speed feels constant.
    static func interpolate(to target: CGRect, canvas: CGSize, amount: Double) -> FrameLayout.Camera {
        let w0 = canvas.width, w1 = target.width
        let width = w0 * pow(w1 / w0, amount)
        let ratio = width / w0
        let origin: CGPoint
        if abs(w0 - w1) < 1e-6 {
            origin = CGPoint(x: target.minX * amount, y: target.minY * amount)
        } else {
            // Fixed point f satisfies f / w0 == (f - o1) / w1 (o0 is the canvas origin).
            let k = 1 / w0 - 1 / w1
            let f = CGPoint(x: (-target.minX / w1) / k, y: (-target.minY / w1) / k)
            origin = CGPoint(x: f.x - f.x * ratio, y: f.y - f.y * ratio)
        }
        return FrameLayout.Camera(viewOrigin: origin, scale: 1 / ratio)
    }
}
