import CoreVideo
import Metal

public enum RenderError: LocalizedError {
    case noMetalDevice
    case textureCacheFailed(CVReturn)
    case pipeline(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .noMetalDevice: "This Mac has no Metal device."
        case let .textureCacheFailed(code): "Couldn't create the video texture cache (\(code))."
        case let .pipeline(name): "Couldn't build the \(name) render pipeline."
        case let .decode(message): "Couldn't decode the video: \(message)"
        }
    }
}

/// Shared GPU objects. One per process; preview and export both render through it.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    /// Zero-copy CVPixelBuffer → MTLTexture bridge for decoded video frames.
    public let textureCache: CVMetalTextureCache
    public let library: MTLLibrary

    public static let shared: MetalContext? = try? MetalContext()

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.noMetalDevice
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw RenderError.textureCacheFailed(status) }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        self.device = device
        self.queue = queue
        self.textureCache = cache
        self.library = try device.makeLibrary(source: shaderSource, options: options)
    }

    /// Wraps a BGRA pixel buffer as an sRGB texture (sampling returns linear light).
    public func makeTexture(from pixelBuffer: CVPixelBuffer) -> FrameTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm_srgb, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return FrameTexture(texture: texture, cvTexture: cvTexture, pixelBuffer: pixelBuffer)
    }
}

/// A decoded video frame on the GPU. Keep it alive until the GPU is done reading it.
public final class FrameTexture: @unchecked Sendable {
    public let texture: MTLTexture
    let cvTexture: CVMetalTexture
    public let pixelBuffer: CVPixelBuffer

    init(texture: MTLTexture, cvTexture: CVMetalTexture, pixelBuffer: CVPixelBuffer) {
        self.texture = texture
        self.cvTexture = cvTexture
        self.pixelBuffer = pixelBuffer
    }
}

/// Pixel buffer attributes for decoders feeding the renderer.
public var rendererPixelBufferAttributes: [String: Any] {
    [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
}
