import CoreGraphics
import ImageIO
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
    private let cursorPipeline: MTLRenderPipelineState
    private let effectPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let layerPipeline: MTLRenderPipelineState
    private let cursorAccumulatePipeline: MTLRenderPipelineState
    private var sceneTexture: MTLTexture?
    private var cursorLayer: MTLTexture?
    private var cursorTextures: [URL: MTLTexture] = [:]
    private let sampler: MTLSamplerState
    private let placeholder: MTLTexture
    private var mipTexture: MTLTexture?
    private var mipsValid = false
    private var images: [String: MTLTexture] = [:]

    public init(context: MetalContext, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) throws {
        self.context = context
        self.pixelFormat = pixelFormat
        let device = context.device

        func pipeline(
            _ fragment: String, blended: Bool, vertex: String = "quad_vertex",
            format: MTLPixelFormat = pixelFormat, additive: Bool = false
        ) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            d.vertexFunction = context.library.makeFunction(name: vertex)
            d.fragmentFunction = context.library.makeFunction(name: fragment)
            let attachment = d.colorAttachments[0]!
            attachment.pixelFormat = format
            if additive {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            } else if blended {
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
        cursorPipeline = try pipeline("cursor_fragment", blended: true, vertex: "corners_vertex")
        effectPipeline = try pipeline("effect_fragment", blended: true)
        blurPipeline = try pipeline("motion_blur_fragment", blended: false, vertex: "fullscreen_vertex")
        copyPipeline = try pipeline("layer_fragment", blended: false, vertex: "fullscreen_vertex")
        layerPipeline = try pipeline("layer_fragment", blended: true, vertex: "fullscreen_vertex")
        cursorAccumulatePipeline = try pipeline("cursor_fragment", blended: false, vertex: "corners_vertex", format: .rgba16Float, additive: true)

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
        into target: MTLTexture, commandBuffer: MTLCommandBuffer, motion: MotionBlurFrame? = nil
    ) {
        guard let motion, let scene = offscreen(&sceneTexture, like: target, format: target.pixelFormat) else {
            encodeScene(layout: layout, source: source, sourceChanged: sourceChanged, into: target, commandBuffer: commandBuffer, drawCursor: true)
            return
        }
        let blurCursor = !motion.cursors.isEmpty
        encodeScene(layout: layout, source: source, sourceChanged: sourceChanged, into: scene, commandBuffer: commandBuffer, drawCursor: !blurCursor)
        var layer: MTLTexture?
        if blurCursor, let cursorTexture = offscreen(&cursorLayer, like: target, format: .rgba16Float) {
            accumulateCursor(motion.cursors, layout: layout, into: cursorTexture, target: target, commandBuffer: commandBuffer)
            layer = cursorTexture
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Motion blur"
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(scene, index: 0)
        if motion.hasCameraMotion {
            let s = Double(target.width) / max(layout.outputSize.width, 1)
            func cam(_ c: FrameLayout.Camera) -> SIMD4<Float> { SIMD4(Float(c.viewOrigin.x), Float(c.viewOrigin.y), Float(c.scale * s), 0) }
            var uniforms: [SIMD4<Float>] = [
                cam(layout.camera), cam(motion.cameraFrom), cam(motion.cameraTo),
                SIMD4(Float(motion.taps), 0, Float(target.width), Float(target.height)),
            ]
            encoder.setRenderPipelineState(blurPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
        } else {
            encoder.setRenderPipelineState(copyPipeline)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let layer {
            encoder.setRenderPipelineState(layerPipeline)
            encoder.setFragmentTexture(layer, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    /// Averages the cursor over the shutter: each sample adds 1/N into a float layer.
    private func accumulateCursor(_ cursors: [FrameLayout.Cursor], layout: FrameLayout, into layer: MTLTexture, target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let texture = cursorTexture(cursors[0].sprite.imageURL) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = layer
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Cursor blur"
        var frame = frameUniforms(layout: layout, target: target)
        encoder.setVertexBytes(&frame, length: MemoryLayout<SIMD4<Float>>.stride * frame.count, index: 0)
        encoder.setRenderPipelineState(cursorAccumulatePipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let weight = 1 / Float(cursors.count)
        for cursor in cursors {
            encoder.setFragmentTexture(cursorTexture(cursor.sprite.imageURL) ?? texture, index: 0)
            var corners = Self.cornerVectors(cursor.corners)
            encoder.setVertexBytes(&corners, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 1)
            var params = SIMD4<Float>(Float(cursor.opacity) * weight, 0, 0, 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }

    private func frameUniforms(layout: FrameLayout, target: MTLTexture) -> [SIMD4<Float>] {
        let canvasSize = layout.outputSize
        let targetScale = Double(target.width) / max(canvasSize.width, 1)
        return [
            SIMD4(Float(layout.camera.viewOrigin.x), Float(layout.camera.viewOrigin.y), Float(layout.camera.scale * targetScale), 0),
            SIMD4(Float(target.width), Float(target.height), Float(canvasSize.width), Float(canvasSize.height)),
        ]
    }

    private func offscreen(_ cache: inout MTLTexture?, like target: MTLTexture, format: MTLPixelFormat) -> MTLTexture? {
        if let t = cache, t.width == target.width, t.height == target.height, t.pixelFormat == format { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: target.width, height: target.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        cache = context.device.makeTexture(descriptor: d)
        return cache
    }

    private func encodeScene(
        layout: FrameLayout, source: MTLTexture?, sourceChanged: Bool,
        into target: MTLTexture, commandBuffer: MTLCommandBuffer, drawCursor shouldDrawCursor: Bool
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

        drawClickEffects(layout.clickEffects, encoder: encoder)
        if shouldDrawCursor, let cursor = layout.cursor { drawCursor(cursor, encoder: encoder) }

        encoder.endEncoding()
    }

    // MARK: Cursor

    private func drawClickEffects(_ effects: [FrameLayout.ClickEffect], encoder: MTLRenderCommandEncoder) {
        guard !effects.isEmpty else { return }
        encoder.setRenderPipelineState(effectPipeline)
        for effect in effects {
            let p = effect.progress
            let eased = 1 - pow(1 - p, 3)
            let radius: Double, thickness: Double, alpha: Double
            switch effect.kind {
            case .ripple:
                radius = effect.maxRadius * (0.25 + 0.75 * eased)
                thickness = max(effect.maxRadius * 0.16 * (1 - p), 0.6)
                alpha = pow(1 - p, 1.4)
            case .pulse:
                radius = effect.maxRadius * 0.85 * eased
                thickness = 0
                alpha = 0.55 * pow(1 - p, 2)
            }
            let extent = radius + thickness + 4
            var quad = SIMD4<Float>(Float(effect.center.x - extent), Float(effect.center.y - extent), Float(extent * 2), Float(extent * 2))
            encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            let c = effect.color
            var uniforms: [SIMD4<Float>] = [
                SIMD4(Float(effect.center.x), Float(effect.center.y), Float(radius), Float(thickness)),
                SIMD4(Float(Self.linear(c.r)), Float(Self.linear(c.g)), Float(Self.linear(c.b)), Float(c.a * alpha)),
            ]
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func drawCursor(_ cursor: FrameLayout.Cursor, encoder: MTLRenderCommandEncoder) {
        guard let texture = cursorTexture(cursor.sprite.imageURL) else { return }
        encoder.setRenderPipelineState(cursorPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)

        var corners = Self.cornerVectors(cursor.corners)
        encoder.setVertexBytes(&corners, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 1)
        var params = SIMD4<Float>(Float(cursor.opacity), 0, 0, 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static func cornerVectors(_ c: [CGPoint]) -> [SIMD4<Float>] {
        [SIMD4(Float(c[0].x), Float(c[0].y), Float(c[1].x), Float(c[1].y)),
         SIMD4(Float(c[2].x), Float(c[2].y), Float(c[3].x), Float(c[3].y))]
    }

    private static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Loads a cursor PNG as premultiplied *linear* half floats with mips: correct edges at any size
    /// and no fringes in the blurred mip levels used for the shadow.
    private func cursorTexture(_ url: URL) -> MTLTexture? {
        if let cached = cursorTextures[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        else { return nil }
        let w = image.width, h = image.height
        var floats = [Float](repeating: 0, count: w * h * 4)
        let drawn: Bool = floats.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let halves = floats.map { Float16($0) }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        guard let texture = context.device.makeTexture(descriptor: d) else { return nil }
        halves.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8)
        }
        if let buffer = context.queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
        }
        cursorTextures[url] = texture
        return texture
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
