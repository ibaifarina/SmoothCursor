import AVFoundation
import Foundation
import SCCore

public enum VideoImportError: LocalizedError {
    case noVideoTrack
    public var errorDescription: String? { "The file has no video track." }
}

/// Copies an existing video into a package and describes it as a recording.
public enum VideoImporter {
    public static func importVideo(from source: URL, into package: URL) async throws -> RecordingInfo {
        let relative = "\(ProjectPackage.mediaDirectory)/screen.\(source.pathExtension.lowercased())"
        let destination = package.appending(path: relative)
        try FileManager.default.copyItem(at: source, to: destination)
        return try await describe(destination, relativePath: relative)
    }

    /// Reads size, frame rate and duration of a movie already inside a package.
    public static func describe(_ url: URL, relativePath: String) async throws -> RecordingInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoImportError.noVideoTrack
        }
        let (naturalSize, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let size = naturalSize.applying(transform)
        return RecordingInfo(
            sourceKind: .imported,
            videoFile: relativePath,
            pixelSize: PixelSize(width: Int(abs(size.width)), height: Int(abs(size.height))),
            displayScale: 1,
            fps: Double(fps),
            duration: duration.seconds
        )
    }
}
