import AVFoundation
import CoreGraphics
import Metal
import SCCore

/// Renders single frames off screen (thumbnails, previews of export settings, tests).
public final class OfflineRenderer {
    public let compositor: Compositor
    private var context: MetalContext { compositor.context }

    public init(context: MetalContext) throws {
        compositor = try Compositor(context: context)
    }

    public func render(layout: FrameLayout, source: CVPixelBuffer?) throws -> CGImage {
        let width = Int(layout.outputSize.width.rounded()), height = Int(layout.outputSize.height.rounded())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: compositor.pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let bytesPerRow = width * 4
        guard let target = context.device.makeTexture(descriptor: d),
              let readback = context.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commandBuffer = context.queue.makeCommandBuffer()
        else { throw RenderError.pipeline("offline target") }

        let frame = source.flatMap(context.makeTexture(from:))
        compositor.encode(layout: layout, source: frame?.texture, sourceChanged: true, into: target, commandBuffer: commandBuffer)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerRow * height
            )
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(frame) {}
        if let error = commandBuffer.error { throw error }

        let data = Data(bytes: readback.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { throw RenderError.pipeline("readback") }
        return image
    }
}

/// Decodes individual frames for offline rendering.
public enum VideoFrameReader {
    /// The frame shown at `seconds` (the last frame starting at or before it).
    public static func pixelBuffer(of url: URL, at seconds: Seconds) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.decode("no video track")
        }
        let duration = try await asset.load(.duration)
        let time = CMTime(seconds: min(max(seconds, 0), max(duration.seconds - 0.001, 0)), preferredTimescale: 600)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: rendererPixelBufferAttributes)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        // Start a little early so the frame covering `time` is included.
        reader.timeRange = CMTimeRange(start: CMTimeMaximum(.zero, time - CMTime(value: 1, timescale: 2)), end: duration)
        guard reader.startReading() else { throw reader.error ?? RenderError.decode("reader") }
        defer { reader.cancelReading() }

        var best: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = sample.imageBuffer else { continue }
            if sample.presentationTimeStamp > time, best != nil { break }
            best = buffer
            if sample.presentationTimeStamp >= time { break }
        }
        guard let best else { throw RenderError.decode("no frame at \(seconds)s") }
        return best
    }
}
