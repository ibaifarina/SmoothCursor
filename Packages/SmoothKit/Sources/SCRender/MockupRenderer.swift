import CoreGraphics
import Metal
import MetalPerformanceShaders
import SCCore
import simd

/// Mirrors `MockupUniforms` in the shader (float4x4s then float4s, no padding surprises).
private struct MockupUniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    var cameraPos: SIMD4<Float>
    var env: SIMD4<Float>
    var screen: SIMD4<Float>
    var island: SIMD4<Float>
    var plateau: SIMD4<Float>
    var frameColor: SIMD4<Float>
    var backColor: SIMD4<Float>
    var misc: SIMD4<Float>
}

/// Draws the 3D phone (shadow + PBR body + live screen) over a frame whose background is already drawn.
final class MockupRenderer {
    static let fovY: Float = 26 * .pi / 180
    static let sampleCount = 4

    private let context: MetalContext
    private let environments: EnvironmentCache
    private let phonePipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let shadowCompositePipeline: MTLRenderPipelineState
    private let accumulatePipeline: MTLRenderPipelineState
    private let layerPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let screenSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState

    private var mesh: (geometry: PhoneGeometry, vertices: MTLBuffer, indices: MTLBuffer, count: Int)?
    private var screenTexture: MTLTexture?
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private var resolved: MTLTexture?
    private var accumulation: MTLTexture?
    private var shadowSoft: MTLTexture?
    private var shadowContact: MTLTexture?
    private var blurScratch: MTLTexture?

    init(context: MetalContext, targetFormat: MTLPixelFormat) throws {
        self.context = context
        environments = try EnvironmentCache(context: context)
        let device = context.device
        let library = context.library

        func make(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: (MTLBlendFactor, MTLBlendFactor)?, samples: Int = 1, depth: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = samples
            let a = d.colorAttachments[0]!
            a.pixelFormat = format
            if let (src, dst) = blend {
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = src; a.destinationRGBBlendFactor = dst
                a.sourceAlphaBlendFactor = src; a.destinationAlphaBlendFactor = dst
            }
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RenderError.pipeline(fragment) }
        }
        phonePipeline = try make("phone_vertex", "phone_fragment", format: .rgba16Float, blend: nil, samples: Self.sampleCount, depth: true)
        shadowPipeline = try make("shadow_vertex", "shadow_mask_fragment", format: .r16Float, blend: nil)
        shadowCompositePipeline = try make("fullscreen_vertex", "shadow_composite_fragment", format: targetFormat, blend: (.one, .oneMinusSourceAlpha))
        accumulatePipeline = try make("fullscreen_vertex", "accumulate_fragment", format: .rgba16Float, blend: (.one, .one))
        layerPipeline = try make("fullscreen_vertex", "layer_fragment", format: targetFormat, blend: (.one, .oneMinusSourceAlpha))

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: ds) else { throw RenderError.pipeline("depth") }
        self.depthState = depthState

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
        s.maxAnisotropy = 16
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        let l = MTLSamplerDescriptor()
        l.minFilter = .linear; l.magFilter = .linear
        guard let screenSampler = device.makeSamplerState(descriptor: s), let linearSampler = device.makeSamplerState(descriptor: l) else {
            throw RenderError.pipeline("samplers")
        }
        self.screenSampler = screenSampler
        self.linearSampler = linearSampler
    }

    func encode(
        _ frame: MockupFrame, source: MTLTexture?, sourceChanged: Bool, into target: MTLTexture,
        commandBuffer: MTLCommandBuffer, compositor: Compositor
    ) {
        guard let env = environments.texture(for: MockupEnvironment(rawValue: frame.settings.environment) ?? .studio),
              let mesh = mesh(for: frame.geometry) else { return }

        // 1. The phone's screen content, with mips for angled sampling.
        let screenSize = frame.screen.outputSize
        guard let screen = texture(&screenTexture, width: Int(screenSize.width), height: Int(screenSize.height),
                                   format: compositor.pixelFormat, mipmapped: true, usage: [.renderTarget, .shaderRead])
        else { return }
        compositor.encodeScene(layout: frame.screen, source: source, sourceChanged: sourceChanged, into: screen,
                               commandBuffer: commandBuffer, drawCursor: true)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: screen)
            blit.endEncoding()
        }

        let aspect = Float(target.width) / Float(max(target.height, 1))
        let main = uniforms(frame, camera: frame.cameras[frame.cameras.count / 2], aspect: aspect)

        // 2. Floor shadow: soft along the light, tight right under the phone.
        drawShadows(frame, uniforms: main, mesh: mesh, target: target, commandBuffer: commandBuffer)

        // 3. The phone, averaged over the shutter when the camera moves.
        let w = target.width, h = target.height
        guard let color = texture(&msaaColor, width: w, height: h, format: .rgba16Float, samples: Self.sampleCount, usage: .renderTarget, storage: .memoryless),
              let depth = texture(&msaaDepth, width: w, height: h, format: .depth32Float, samples: Self.sampleCount, usage: .renderTarget, storage: .memoryless),
              let resolved = texture(&resolved, width: w, height: h, format: .rgba16Float, usage: [.renderTarget, .shaderRead])
        else { return }
        let blurred = frame.cameras.count > 1
        let accumulation = blurred ? texture(&accumulation, width: w, height: h, format: .rgba16Float, usage: [.renderTarget, .shaderRead]) : nil

        for (i, camera) in frame.cameras.enumerated() {
            var u = frame.cameras.count == 1 ? main : uniforms(frame, camera: camera, aspect: aspect)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].resolveTexture = resolved
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .dontCare
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.label = "Phone"
            encoder.setRenderPipelineState(phonePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<MockupUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<MockupUniforms>.stride, index: 1)
            encoder.setFragmentTexture(env, index: 0)
            encoder.setFragmentTexture(screen, index: 1)
            encoder.setFragmentSamplerState(environments.sampler, index: 0)
            encoder.setFragmentSamplerState(screenSampler, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
            encoder.endEncoding()

            if let accumulation {
                fullscreen(accumulatePipeline, into: accumulation, clear: i == 0, commandBuffer: commandBuffer) { e in
                    var weight = SIMD4<Float>(1 / Float(frame.cameras.count), 0, 0, 0)
                    e.setFragmentBytes(&weight, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    e.setFragmentTexture(resolved, index: 0)
                    e.setFragmentSamplerState(linearSampler, index: 0)
                }
            }
        }

        let layer = accumulation ?? resolved
        fullscreen(layerPipeline, into: target, clear: false, commandBuffer: commandBuffer) { e in
            e.setFragmentTexture(layer, index: 0)
            e.setFragmentSamplerState(linearSampler, index: 0)
        }
    }

    // MARK: Camera & materials

    private func uniforms(_ frame: MockupFrame, camera: Camera3D, aspect: Float) -> MockupUniforms {
        let g = frame.geometry
        let half = g.worldHalf(landscape: frame.landscape)
        let hh = Float(half.height), hw = Float(half.width)
        // Distance at which the phone (plus the canvas padding) just fits the frame.
        let tanY = tan(Self.fovY / 2)
        let margin = 1 + 3 * Float(frame.padding) + 0.04
        let fit = max(hh / tanY, hw / (tanY * aspect)) * margin + Float(g.thickness / 2)
        let distance = fit * Float(camera.distance)
        let target = SIMD3<Float>(Float(camera.target.x) * hh, Float(camera.target.y) * hh, 0)
        let yaw = Float(camera.yaw), pitch = Float(camera.pitch)
        let eye = target + distance * SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up0 = simd_cross(right, forward)
        let roll = Float(camera.roll)
        let up = up0 * cos(roll) + right * sin(roll)
        let view = matrix_float4x4.lookAt(eye: eye, target: target, up: up)
        let projection = matrix_float4x4.perspective(fovY: Self.fovY, aspect: aspect, near: max(distance * 0.05, 1), far: distance * 10 + 2000)
        let model = frame.landscape ? matrix_float4x4(rotationZ: .pi / 2) : matrix_identity_float4x4

        let (frameColor, frameRough, backColor, backRough) = Self.finish(frame.settings.finish)
        let s = frame.settings
        return MockupUniforms(
            viewProj: projection * view,
            model: model,
            cameraPos: SIMD4(eye, 1),
            env: SIMD4(Float(s.lightYaw * .pi / 180), Float(s.lightPitch * .pi / 180), Float(s.lightStrength), 6),
            screen: SIMD4(Float(g.screen.width / 2), Float(g.screen.height / 2), Float(g.screenRadius), frame.landscape ? 1 : 0),
            island: SIMD4(Float(g.islandCenterY), Float(g.islandSize.width / 2), Float(g.islandSize.height / 2), 0),
            plateau: SIMD4(Float(g.plateauCenter.x), Float(g.plateauCenter.y), Float(g.plateauSize), 0),
            frameColor: SIMD4(frameColor, frameRough),
            backColor: SIMD4(backColor, backRough),
            misc: SIMD4(Float(s.screenReflection), -hh * 1.03, 0, 0)
        )
    }

    /// Linear-light colors and roughness for frame and back glass.
    static func finish(_ f: MockupSettings.Finish) -> (SIMD3<Float>, Float, SIMD3<Float>, Float) {
        func lin(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
            func c(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return SIMD3(c(r), c(g), c(b))
        }
        switch f {
        case .black: return (lin(0.33, 0.33, 0.34), 0.3, lin(0.13, 0.13, 0.14), 0.42)
        case .silver: return (lin(0.9, 0.9, 0.91), 0.26, lin(0.93, 0.93, 0.94), 0.45)
        case .natural: return (lin(0.72, 0.7, 0.66), 0.3, lin(0.8, 0.78, 0.74), 0.42)
        case .desert: return (lin(0.82, 0.71, 0.58), 0.3, lin(0.86, 0.78, 0.68), 0.42)
        case .blue: return (lin(0.3, 0.37, 0.48), 0.3, lin(0.24, 0.3, 0.41), 0.42)
        }
    }

    // MARK: Shadows

    private func drawShadows(_ frame: MockupFrame, uniforms u: MockupUniforms, mesh: (geometry: PhoneGeometry, vertices: MTLBuffer, indices: MTLBuffer, count: Int),
                             target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let opacity = Float(frame.settings.shadowOpacity)
        guard opacity > 0.001 else { return }
        let w = max(target.width / 2, 1), h = max(target.height / 2, 1)
        guard let soft = texture(&shadowSoft, width: w, height: h, format: .r16Float, usage: [.renderTarget, .shaderRead, .shaderWrite]),
              let contact = texture(&shadowContact, width: w, height: h, format: .r16Float, usage: [.renderTarget, .shaderRead, .shaderWrite]),
              let scratch = texture(&blurScratch, width: w, height: h, format: .r16Float, usage: [.renderTarget, .shaderRead, .shaderWrite])
        else { return }

        let s = frame.settings
        let yaw = Float(s.lightYaw * .pi / 180)
        let elevation = Float(min(max(58 + s.lightPitch, 15), 85) * .pi / 180)
        let fromLight = SIMD3<Float>(sin(yaw) * cos(elevation), sin(elevation), cos(yaw) * cos(elevation))
        for (texture, light) in [(soft, -fromLight), (contact, SIMD3<Float>(0, -1, 0))] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let e = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            var uu = u
            var l = SIMD4<Float>(light, 0)
            e.setRenderPipelineState(shadowPipeline)
            e.setCullMode(.none)
            e.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            e.setVertexBytes(&uu, length: MemoryLayout<MockupUniforms>.stride, index: 1)
            e.setVertexBytes(&l, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            e.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
            e.endEncoding()
        }
        let ref = Float(min(w, h))
        blur(soft, sigma: ref * 0.045, scratch: scratch, commandBuffer: commandBuffer)
        blur(contact, sigma: ref * 0.012, scratch: scratch, commandBuffer: commandBuffer)

        fullscreen(shadowCompositePipeline, into: target, clear: false, commandBuffer: commandBuffer) { e in
            var p = SIMD4<Float>(0.85 * opacity, 1.1 * opacity, 0, 0)
            e.setFragmentBytes(&p, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            e.setFragmentTexture(soft, index: 0)
            e.setFragmentTexture(contact, index: 1)
            e.setFragmentSamplerState(linearSampler, index: 0)
        }
    }

    private func blur(_ texture: MTLTexture, sigma: Float, scratch: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let kernel = MPSImageGaussianBlur(device: context.device, sigma: max(sigma, 0.5))
        kernel.edgeMode = .zero
        kernel.encode(commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: scratch)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: scratch, to: texture)
            blit.endEncoding()
        }
    }

    // MARK: Helpers

    private func mesh(for geometry: PhoneGeometry) -> (geometry: PhoneGeometry, vertices: MTLBuffer, indices: MTLBuffer, count: Int)? {
        if let mesh, mesh.geometry == geometry { return mesh }
        guard let built = PhoneMesh.build(geometry, device: context.device) else { return nil }
        mesh = (geometry, built.vertices, built.indices, built.count)
        return mesh
    }

    private func fullscreen(_ pipeline: MTLRenderPipelineState, into target: MTLTexture, clear: Bool, commandBuffer: MTLCommandBuffer, configure: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let e = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(pipeline)
        configure(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    private func texture(
        _ cache: inout MTLTexture?, width: Int, height: Int, format: MTLPixelFormat, samples: Int = 1, mipmapped: Bool = false,
        usage: MTLTextureUsage, storage: MTLStorageMode = .private
    ) -> MTLTexture? {
        if let t = cache, t.width == width, t.height == height, t.pixelFormat == format { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width, 1), height: max(height, 1), mipmapped: mipmapped)
        if samples > 1 {
            d.textureType = .type2DMultisample
            d.sampleCount = samples
        }
        d.usage = usage
        d.storageMode = storage
        cache = context.device.makeTexture(descriptor: d)
        return cache
    }
}
