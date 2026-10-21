import Metal
import SCCore

/// Everything needed to draw one output frame. Built from the project + time by the evaluator (step 3).
public struct FrameDescriptor: Sendable {
    public var time: Seconds
    public var outputSize: PixelSize
    public var project: Project
    public init(time: Seconds, outputSize: PixelSize, project: Project) {
        self.time = time; self.outputSize = outputSize; self.project = project
    }
}

/// A compositor stage: background, screen, mockup, cursor, overlays, motion blur.
public protocol RenderPass: AnyObject {
    func encode(_ frame: FrameDescriptor, source: MTLTexture?, into target: MTLTexture, commandBuffer: MTLCommandBuffer)
}
