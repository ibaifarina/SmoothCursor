import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image backgrounds: macOS wallpapers, imported files and frames of the recording.
/// Whatever is chosen is copied into the package (≤ 4K JPEG) so projects stay self-contained.
public enum BackgroundImages {
    public static let wallpaperFolder = URL(fileURLWithPath: "/System/Library/Desktop Pictures")

    /// Full-resolution wallpapers shipped with macOS.
    public static func systemWallpapers() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: wallpaperFolder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func thumbnail(of url: URL, maxPixelSize: Int = 240) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// Copies an image file into the package. Returns the package-relative path.
    public static func importImage(_ url: URL, into package: URL) throws -> String {
        guard let image = thumbnail(of: url, maxPixelSize: 3840) else { throw CocoaError(.fileReadCorruptFile) }
        return try importImage(image, into: package)
    }

    public static func importImage(_ image: CGImage, into package: URL) throws -> String {
        // Unique names: renderer texture caches are keyed by path.
        let relative = "media/background-\(UUID().uuidString.prefix(8)).jpg"
        let url = package.appending(path: relative)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return relative
    }
}
