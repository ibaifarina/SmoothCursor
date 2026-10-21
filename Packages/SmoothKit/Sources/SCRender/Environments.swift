import CoreGraphics
import Metal
import SCCore
import simd

/// Procedural HDR lighting environments (equirectangular), prefiltered per roughness on the GPU.
///
/// Layouts are written "as seen with the default light yaw (150°)": the camera looks from +z,
/// the area straight behind the camera is kept dark so screens stay readable, and soft boxes sit
/// off-axis to put long glints on the frame and glass.
enum EnvironmentMaps {
    static let width = 768, height = 384
    static let defaultYaw = 150.0

    struct Box {
        var azimuth: Double, elevation: Double   // degrees, world at default yaw
        var width: Double, height: Double        // degrees
        var color: SIMD3<Double>
        var softness = 6.0
    }

    struct Layout {
        var sky: SIMD3<Double>, horizon: SIMD3<Double>, ground: SIMD3<Double>
        var boxes: [Box]
        var sun: (azimuth: Double, elevation: Double, color: SIMD3<Double>)?
    }

    static func layout(_ env: MockupEnvironment) -> Layout {
        switch env {
        case .studio:
            return Layout(sky: SIMD3(0.05, 0.05, 0.055), horizon: SIMD3(0.03, 0.03, 0.032), ground: SIMD3(0.012, 0.012, 0.013), boxes: [
                Box(azimuth: -38, elevation: 34, width: 44, height: 58, color: SIMD3(4.2, 4.1, 4.0)),
                Box(azimuth: 58, elevation: 14, width: 28, height: 56, color: SIMD3(1.3, 1.32, 1.4)),
                Box(azimuth: 0, elevation: 82, width: 80, height: 42, color: SIMD3(1.8, 1.8, 1.8), softness: 14),
                Box(azimuth: 150, elevation: 20, width: 9, height: 72, color: SIMD3(3.5, 3.5, 3.6), softness: 3),
                Box(azimuth: -150, elevation: 20, width: 9, height: 72, color: SIMD3(3.5, 3.5, 3.6), softness: 3),
            ])
        case .soft:
            return Layout(sky: SIMD3(1.0, 1.0, 1.04), horizon: SIMD3(0.72, 0.72, 0.74), ground: SIMD3(0.34, 0.32, 0.3), boxes: [
                Box(azimuth: -30, elevation: 22, width: 62, height: 52, color: SIMD3(2.4, 2.4, 2.35), softness: 18),
                Box(azimuth: 120, elevation: 30, width: 50, height: 40, color: SIMD3(1.3, 1.3, 1.3), softness: 18),
            ])
        case .sunset:
            return Layout(sky: SIMD3(0.12, 0.2, 0.5), horizon: SIMD3(1.3, 0.6, 0.26), ground: SIMD3(0.07, 0.045, 0.04), boxes: [
                Box(azimuth: 160, elevation: 10, width: 120, height: 18, color: SIMD3(0.9, 0.35, 0.2), softness: 20),
            ], sun: (-55, 7, SIMD3(40, 22, 9)))
        case .neon:
            return Layout(sky: SIMD3(0.012, 0.012, 0.03), horizon: SIMD3(0.02, 0.012, 0.035), ground: SIMD3(0.005, 0.005, 0.01), boxes: [
                Box(azimuth: -70, elevation: 12, width: 10, height: 80, color: SIMD3(5, 0.7, 2.8), softness: 3),
                Box(azimuth: 70, elevation: 12, width: 10, height: 80, color: SIMD3(0.5, 3.6, 5), softness: 3),
                Box(azimuth: 0, elevation: 80, width: 60, height: 30, color: SIMD3(0.6, 0.5, 0.9), softness: 12),
                Box(azimuth: 180, elevation: 25, width: 30, height: 10, color: SIMD3(3, 1.2, 4), softness: 4),
            ])
        case .white:
            return Layout(sky: SIMD3(0.95, 0.95, 0.96), horizon: SIMD3(0.8, 0.8, 0.81), ground: SIMD3(0.55, 0.55, 0.56), boxes: [
                Box(azimuth: -40, elevation: 30, width: 50, height: 60, color: SIMD3(3.2, 3.2, 3.2), softness: 10),
                Box(azimuth: 55, elevation: 20, width: 40, height: 55, color: SIMD3(2.2, 2.2, 2.2), softness: 10),
                Box(azimuth: 0, elevation: -2, width: 40, height: 14, color: SIMD3(0.35, 0.35, 0.36), softness: 10),
            ])
        }
    }

    static func direction(azimuth: Double, elevation: Double) -> SIMD3<Double> {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        return SIMD3(sin(a) * cos(e), sin(e), cos(a) * cos(e))
    }

    /// Radiance in env space (the default yaw is undone so the shader's yaw rotation lines up).
    static func radiance(_ d: SIMD3<Double>, _ l: Layout) -> SIMD3<Double> {
        let y = d.y
        var c: SIMD3<Double> = y >= 0
            ? l.horizon + (l.sky - l.horizon) * pow(y, 0.6)
            : l.horizon + (l.ground - l.horizon) * min(-y * 4, 1)
        for box in l.boxes {
            let center = direction(azimuth: box.azimuth - defaultYaw, elevation: box.elevation)
            let cd = simd_dot(d, center)
            guard cd > 0 else { continue }
            let up = abs(center.y) > 0.95 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            let t = simd_normalize(simd_cross(up, center)), b = simd_cross(center, t)
            let x = atan2(simd_dot(d, t), cd) * 180 / .pi, yy = atan2(simd_dot(d, b), cd) * 180 / .pi
            func edge(_ v: Double, _ size: Double) -> Double {
                let s = box.softness
                return 1 - smooth(min(max((abs(v) - size / 2 + s) / (2 * s), 0), 1))
            }
            c += box.color * edge(x, box.width) * edge(yy, box.height)
        }
        if let sun = l.sun {
            let center = direction(azimuth: sun.azimuth - defaultYaw, elevation: sun.elevation)
            let angle = acos(min(max(simd_dot(d, center), -1), 1)) * 180 / .pi
            c += sun.color * (angle < 2.5 ? 1 : 0) + sun.color * 0.02 * exp(-angle / 10)
        }
        return c
    }

    private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// Equirect texel → direction, matching the shader's `equirect_dir`.
    static func direction(u: Double, v: Double) -> SIMD3<Double> {
        let phi = (u - 0.5) * 2 * .pi, theta = v * .pi
        return SIMD3(sin(theta) * sin(phi), cos(theta), -sin(theta) * cos(phi))
    }

    static func pixels(_ env: MockupEnvironment, width: Int = width, height: Int = height) -> [Float16] {
        let l = layout(env)
        var out = [Float16](repeating: 0, count: width * height * 4)
        for j in 0..<height {
            for i in 0..<width {
                let c = radiance(direction(u: (Double(i) + 0.5) / Double(width), v: (Double(j) + 0.5) / Double(height)), l)
                let k = (j * width + i) * 4
                out[k] = Float16(c.x); out[k + 1] = Float16(c.y); out[k + 2] = Float16(c.z); out[k + 3] = 1
            }
        }
        return out
    }

    /// Small tone-mapped preview of the half facing the camera, for the inspector.
    static func thumbnail(_ env: MockupEnvironment, width: Int = 120, height: Int = 60) -> CGImage? {
        let l = layout(env)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for j in 0..<height {
            for i in 0..<width {
                // Front hemisphere, as the viewer sees it.
                let az = (Double(i) / Double(width) - 0.5) * 220, el = (0.5 - Double(j) / Double(height)) * 110
                // World direction → env space, as the shader does at the default yaw.
                let c = radiance(rotateY(direction(azimuth: az, elevation: el), -defaultYaw), l)
                for (ch, v) in [c.x, c.y, c.z].enumerated() {
                    let t = v * (2.51 * v + 0.03) / (v * (2.43 * v + 0.59) + 0.14)
                    let s = t <= 0.0031308 ? t * 12.92 : 1.055 * pow(t, 1 / 2.4) - 0.055
                    bytes[(j * width + i) * 4 + ch] = UInt8(min(max(s, 0), 1) * 255)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func rotateY(_ d: SIMD3<Double>, _ degrees: Double) -> SIMD3<Double> {
        let a = degrees * .pi / 180
        return SIMD3(d.x * cos(a) + d.z * sin(a), d.y, -d.x * sin(a) + d.z * cos(a))
    }
}

/// GPU environment textures: level k holds radiance prefiltered for roughness k / (levels − 1).
final class EnvironmentCache {
    private let context: MetalContext
    private let prefilterPipeline: MTLRenderPipelineState
    private var textures: [MockupEnvironment: MTLTexture] = [:]
    let sampler: MTLSamplerState

    init(context: MetalContext) throws {
        self.context = context
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = context.library.makeFunction(name: "fullscreen_vertex")
        d.fragmentFunction = context.library.makeFunction(name: "prefilter_fragment")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        prefilterPipeline = try context.device.makeRenderPipelineState(descriptor: d)
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
        s.sAddressMode = .repeat; s.tAddressMode = .clampToEdge
        guard let sampler = context.device.makeSamplerState(descriptor: s) else { throw RenderError.pipeline("env sampler") }
        self.sampler = sampler
    }

    func texture(for env: MockupEnvironment) -> MTLTexture? {
        if let t = textures[env] { return t }
        let w = EnvironmentMaps.width, h = EnvironmentMaps.height
        let levels = 7
        let pixels = EnvironmentMaps.pixels(env)
        let device = context.device

        // Source with box-filtered mips (sampled while prefiltering).
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
        sd.usage = [.shaderRead]
        sd.storageMode = .managed
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
        rd.mipmapLevelCount = levels
        rd.usage = [.shaderRead, .renderTarget]
        rd.storageMode = .private
        guard let source = device.makeTexture(descriptor: sd), let result = device.makeTexture(descriptor: rd),
              let buffer = context.queue.makeCommandBuffer() else { return nil }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: source)
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: result, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
        }
        for level in 1..<levels {
            guard let view = result.makeTextureView(pixelFormat: .rgba16Float, textureType: .type2D, levels: level..<(level + 1), slices: 0..<1)
            else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = view
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setRenderPipelineState(prefilterPipeline)
            var params = SIMD4<Float>(Float(level) / Float(levels - 1), Float(w), Float(h), 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        textures[env] = result
        return result
    }
}

/// Public previews for the inspector.
public enum MockupPreviews {
    public static func environmentThumbnail(_ env: MockupEnvironment) -> CGImage? {
        EnvironmentMaps.thumbnail(env)
    }
}
