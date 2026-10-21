import AppKit
import AVFoundation
import SCCore

/// Poster frames for the library grid, stored as `thumbnail.jpg` inside each package.
public enum Thumbnailer {
    /// Returns the thumbnail URL, generating it from the first second of video if missing.
    public static func ensureThumbnail(for packageURL: URL) async -> URL? {
        let url = packageURL.appending(path: ProjectPackage.thumbnailFile)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let project = try? ProjectPackage.read(at: packageURL),
              let image = await frame(of: ProjectPackage.mediaURL(project.recording.videoFile, in: packageURL), at: 0.5, maxSize: 640)
        else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    public static func frame(of videoURL: URL, at seconds: Double, maxSize: CGFloat? = nil) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        if let maxSize { generator.maximumSize = CGSize(width: maxSize, height: maxSize) }
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}
