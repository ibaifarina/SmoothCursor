import AppKit
import QuartzCore
import SCCore

/// Live Metal preview of a project. Driven by a display link that pauses itself when idle
/// (paused, nothing changing) so an open editor costs no GPU time.
@MainActor
public final class PreviewView: NSView {
    public var project: Project? {
        didSet { if project != oldValue { setNeedsRender() } }
    }

    /// Cursor to draw (nil for recordings without telemetry). Replaced whole when settings change.
    public var cursorTrack: CursorTrack? {
        didSet { setNeedsRender() }
    }

    /// Camera motion from zoom segments (nil = no zooms).
    public var cameraTrack: CameraTrack? {
        didSet { setNeedsRender() }
    }

    /// Shows the whole uncropped recording for crop editing.
    public var cropEditing = false {
        didSet { if cropEditing != oldValue { setNeedsRender() } }
    }

    public var playback: PlaybackController? {
        didSet {
            guard playback !== oldValue else { return }
            oldValue?.onActivity = nil
            playback?.onActivity = { [weak self] in self?.setNeedsRender() }
            currentFrame = nil
            setNeedsRender()
        }
    }

    public var imageResolver: (ImageBackground.Source) -> URL? = { _ in nil } {
        didSet { compositor?.imageResolver = imageResolver; setNeedsRender() }
    }

    private let metalLayer = CAMetalLayer()
    private let context: MetalContext?
    private var compositor: Compositor?
    private var link: CADisplayLink?
    private var currentFrame: FrameTexture?
    private var frameChanged = false
    private var dirty = true
    private var idleTicks = 0

    override public init(frame: NSRect) {
        context = MetalContext.shared
        super.init(frame: frame)
        compositor = context.flatMap { try? Compositor(context: $0) }
        metalLayer.device = context?.device
        metalLayer.pixelFormat = compositor?.pixelFormat ?? .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func setNeedsRender() {
        dirty = true
        idleTicks = 0
        link?.isPaused = false
    }

    // MARK: Lifecycle

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        // Common modes: keep rendering while sliders and the timeline are being dragged.
        link.add(to: .main, forMode: .common)
        self.link = link
        updateDrawableSize()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1).rounded(), height: max(bounds.height * scale, 1).rounded())
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            setNeedsRender()
        }
    }

    // MARK: Rendering

    @objc private func tick(_ link: CADisplayLink) {
        var time = playback?.time ?? 0
        if let playback, let context {
            time = playback.itemTime(forHostTime: link.targetTimestamp)
            if let buffer = playback.newPixelBuffer(forItemTime: time), let frame = context.makeTexture(from: buffer) {
                currentFrame = frame
                frameChanged = true
                dirty = true
            }
        }
        let playing = playback?.isPlaying ?? false
        if dirty || playing {
            dirty = false
            idleTicks = 0
            render(time: time)
        } else {
            idleTicks += 1
            if idleTicks > 30, !(playback?.isSeeking ?? false) { link.isPaused = true }
        }
    }

    private func render(time: Seconds) {
        guard let project, let compositor, let context,
              metalLayer.drawableSize.width > 1, metalLayer.drawableSize.height > 1,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = context.queue.makeCommandBuffer()
        else { return }
        commandBuffer.label = "Preview"
        let size = metalLayer.drawableSize
        let layout = cropEditing
            ? FrameLayout.cropEditing(project: project, outputSize: size)
            : FrameLayout.make(project: project, time: time, outputSize: size, cursor: cursorTrack, camera: cameraTrack)
        let motion = cropEditing ? nil : FrameLayout.motionBlur(
            project: project, time: time, outputSize: size, cursor: cursorTrack, camera: cameraTrack,
            frameDuration: 1 / Double(max(project.export.fps, 1)), quality: .preview
        )
        compositor.encode(
            layout: layout, source: currentFrame?.texture, sourceChanged: frameChanged,
            into: drawable.texture, commandBuffer: commandBuffer, motion: motion
        )
        frameChanged = false
        let frame = currentFrame
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
