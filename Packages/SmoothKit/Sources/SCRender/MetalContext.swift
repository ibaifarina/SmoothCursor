import CoreVideo
import Metal

public enum RenderError: Error { case noMetalDevice, textureCacheFailed(CVReturn) }

/// Shared GPU objects. One per process; preview and export both render through it.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    /// Zero-copy CVPixelBuffer → MTLTexture bridge for decoded video frames.
    public let textureCache: CVMetalTextureCache

    public static let shared: MetalContext? = try? MetalContext()

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.noMetalDevice
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw RenderError.textureCacheFailed(status) }
        self.device = device
        self.queue = queue
        self.textureCache = cache
    }
}
