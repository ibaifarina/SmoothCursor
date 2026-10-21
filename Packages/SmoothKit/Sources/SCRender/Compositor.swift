import CoreGraphics
import Metal
import MetalPerformanceShaders
import MetalKit
import SCCore

/// Draws one frame — background, shadow, recording — in a single render pass.
/// Used unchanged by the live preview and by export, so they match pixel for pixel.
public final class Compositor {
    public let context: MetalContext
    public let pixelFormat: MTLPixelFormat
    /// Resolves image backgrounds to files (project packages, bundled wallpapers).
    public var imageResolver: (ImageBackground.Source) -> URL? = { _ in nil }

    private let backgroundPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let screenPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let placeholder: MTLTexture
    private var mipTexture: MTLTexture?
    private var mipsValid = false
    private var images: [String: MTLTexture] = [:]

    public init(context: MetalContext, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) throws {
        self.context = context
        self.pixelFormat = pixelFormat
        let device = context.device

        func pipeline(_ fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            d.vertexFunction = context.library.makeFunction(name: "quad_vertex")
            d.fragmentFunction = context.library.makeFunction(name: fragment)
            let attachment = d.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            if blended {
                // Premultiplied alpha.
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RenderError.pipeline(fragment) }
        }
        backgroundPipeline = try pipeline("background_fragment", blended: false)
        shadowPipeline = try pipeline("shadow_fragment", blended: true)
        screenPipeline = try pipeline("screen_fragment", blended: true)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else { throw RenderError.pipeline("sampler") }
        self.sampler = sampler

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        guard let placeholder = device.makeTexture(descriptor: td) else { throw RenderError.pipeline("placeholder") }
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](arrayLiteral: 0, 0, 0, 255), bytesPerRow: 4)
        self.placeholder = placeholder
    }

    /// Encodes the frame into `target`. `sourceChanged` must be true whenever `source` holds a new
    /// video frame, so cached mip levels are rebuilt.
    public func encode(
        layout: FrameLayout, source: MTLTexture?, sourceChanged: Bool,
        into target: MTLTexture, commandBuffer: MTLCommandBuffer
    ) {
        let filter = filterMode(layout: layout, source: source)
        var screenTexture = source ?? placeholder
        if filter == 1, let source {
            screenTexture = mipmapped(source, changed: sourceChanged, commandBuffer: commandBuffer)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Compositor"

        let canvasSize = layout.outputSize
        var frame: [SIMD4<Float>] = [
            SIMD4(Float(layout.camera.viewOrigin.x), Float(layout.camera.viewOrigin.y), Float(layout.camera.scale), 0),
            SIMD4(Float(target.width), Float(target.height), Float(canvasSize.width), Float(canvasSize.height)),
        ]
        // Canvas units are output pixels of `layout.outputSize`; rescale if the target differs.
        let targetScale = Double(target.width) / max(canvasSize.width, 1)
        frame[0].z = Float(layout.camera.scale * targetScale)
        encoder.setVertexBytes(&frame, length: MemoryLayout<SIMD4<Float>>.stride * frame.count, index: 0)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<SIMD4<Float>>.stride * frame.count, index: 0)

        // Background: the visible part of the canvas.
        encoder.setRenderPipelineState(backgroundPipeline)
        var visible = rectVector(layout.visibleCanvasRect)
        encoder.setVertexBytes(&visible, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        var background = backgroundUniforms(layout.background, noise: layout.backgroundNoise, canvas: canvasSize)
        encoder.setFragmentBytes(&background.values, length: MemoryLayout<SIMD4<Float>>.stride * background.values.count, index: 1)
        encoder.setFragmentTexture(background.image ?? placeholder, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Shadow under the recording.
        let screen = layout.screenRect
        if let shadow = layout.shadow {
            encoder.setRenderPipelineState(shadowPipeline)
            let caster = screen.offsetBy(dx: 0, dy: shadow.offsetY)
            var quad = rectVector(caster.insetBy(dx: -3 * shadow.sigma, dy: -3 * shadow.sigma))
            encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            var uniforms: [SIMD4<Float>] = [
                rectVector(caster),
                SIMD4(Float(shadow.sigma), Float(layout.cornerRadius), Float(shadow.opacity), 0),
            ]
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // The recording.
        encoder.setRenderPipelineState(screenPipeline)
        var quad = rectVector(screen)
        encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        let crop = layout.sourceCrop
        var uniforms: [SIMD4<Float>] = [
            rectVector(screen),
            SIMD4(Float(crop.x), Float(crop.y), Float(crop.width), Float(crop.height)),
            SIMD4(Float(layout.cornerRadius), Float(filter), Float(screenTexture.width), Float(screenTexture.height)),
        ]
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 1)
        encoder.setFragmentTexture(screenTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.endEncoding()
    }

    // MARK: Source filtering

    /// 0 bilinear (≈1:1), 1 trilinear mips (minifying: keeps text from shimmering), 2 bicubic (magnifying).
    private func filterMode(layout: FrameLayout, source: MTLTexture?) -> Int {
        guard let source else { return 0 }
        let sourcePixels = Double(source.width) * layout.sourceCrop.width
        guard sourcePixels > 0 else { return 0 }
        let outputPerSource = layout.screenRect.width * layout.camera.scale / sourcePixels
        if outputPerSource < 0.95 { return 1 }
        if outputPerSource > 1.05 { return 2 }
        return 0
    }

    private func mipmapped(_ source: MTLTexture, changed: Bool, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        if mipTexture?.width != source.width || mipTexture?.height != source.height || mipTexture?.pixelFormat != source.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: true
            )
            d.storageMode = .private
            d.usage = [.shaderRead]
            mipTexture = context.device.makeTexture(descriptor: d)
            mipsValid = false
        }
        guard let mipTexture else { return source }
        if changed || !mipsValid, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "Source mips"
            blit.copy(
                from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                to: mipTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin()
            )
            blit.generateMipmaps(for: mipTexture)
            blit.endEncoding()
            mipsValid = true
        }
        return mipTexture
    }

    // MARK: Background

    private func backgroundUniforms(_ background: Background, noise: Double, canvas: CGSize) -> (values: [SIMD4<Float>], image: MTLTexture?) {
        // Layout: params, center, colors[8], locations[2], mesh[9], imageTransform.
        var values = [SIMD4<Float>](repeating: .zero, count: 22)
        values[0].w = Float(noise)
        values[1] = SIMD4(0.5, 0.5, 0, 0)
        var image: MTLTexture?

        func srgb(_ c: RGBAColor) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), 1) }

        switch background {
        case let .color(color):
            values[0].x = 0
            values[2] = srgb(color)
        case let .gradient(spec):
            let kind: Float = switch spec.kind {
            case .linear: 1
            case .radial: 2
            case .angular: 3
            case .mesh: 4
            }
            values[0].x = kind
            values[0].y = Float(spec.angle * .pi / 180)
            values[1] = SIMD4(Float(spec.center.x), Float(spec.center.y), 0, 0)
            let stops = spec.stops.sorted { $0.location < $1.location }.prefix(8)
            values[0].z = Float(max(stops.count, 1))
            for (i, stop) in stops.enumerated() {
                values[2 + i] = srgb(stop.color)
                values[10 + i / 4][i % 4] = Float(stop.location)
            }
            if stops.isEmpty { values[2] = SIMD4(0, 0, 0, 1) }
            if spec.kind == .mesh {
                let mesh = spec.meshColors.count == 9 ? spec.meshColors : Array(repeating: stops.first?.color ?? .black, count: 9)
                for (i, c) in mesh.enumerated() { values[12 + i] = srgb(c) }
            }
        case let .image(spec):
            if let texture = loadImage(spec) {
                values[0].x = 5
                image = texture
                let canvasAspect = canvas.width / max(canvas.height, 1)
                let imageAspect = Double(texture.width) / Double(max(texture.height, 1))
                // Aspect fill.
                if imageAspect > canvasAspect {
                    let s = canvasAspect / imageAspect
                    values[21] = SIMD4(Float(s), 1, Float((1 - s) / 2), 0)
                } else {
                    let s = imageAspect / canvasAspect
                    values[21] = SIMD4(1, Float(s), 0, Float((1 - s) / 2))
                }
            } else {
                values[0].x = 0
                values[2] = SIMD4(0.1, 0.1, 0.11, 1)
            }
        }
        return (values, image)
    }

    private func loadImage(_ spec: ImageBackground) -> MTLTexture? {
        guard let url = imageResolver(spec.source) else { return nil }
        let key = "\(url.path)#\(spec.blur)"
        if let cached = images[key] { return cached }
        let loader = MTKTextureLoader(device: context.device)
        guard let base = try? loader.newTexture(URL: url, options: [
            .SRGB: true, .textureStorageMode: MTLStorageMode.private.rawValue,
            .textureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue,
        ]) else { return nil }
        var result = base
        if spec.blur > 0, let blurred = blur(base, amount: spec.blur) { result = blurred }
        images[key] = result
        return result
    }

    private func blur(_ texture: MTLTexture, amount: Double) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false
        )
        d.storageMode = .private
        d.usage = [.shaderRead, .shaderWrite]
        guard let output = context.device.makeTexture(descriptor: d), let buffer = context.queue.makeCommandBuffer() else { return nil }
        let sigma = Float(amount * Double(min(texture.width, texture.height)) * 0.04)
        let kernel = MPSImageGaussianBlur(device: context.device, sigma: max(sigma, 0.1))
        kernel.edgeMode = .clamp
        kernel.encode(commandBuffer: buffer, sourceTexture: texture, destinationTexture: output)
        buffer.commit()
        buffer.waitUntilCompleted()
        return output
    }

    private func rectVector(_ r: CGRect) -> SIMD4<Float> {
        SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
    }
}
