import Foundation
import SCCore
import SCRender

public struct ExportProgress: Sendable {
    public var fraction: Double
    public var framesRendered: Int
    public var totalFrames: Int
}

/// Renders a project through the shared render graph and encodes it. Implemented in step 8.
public protocol Exporter: Sendable {
    func export(
        project: Project, packageURL: URL, to destination: URL,
        progress: @Sendable (ExportProgress) -> Void
    ) async throws
}
