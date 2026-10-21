import CoreGraphics
import Foundation

/// A set of cursor images replacing macOS cursors by kind ("arrow", "pointingHand", "iBeam", …).
/// The kind `*` replaces every cursor. Stored as `pack.json` + PNGs in its own folder.
public struct CursorPack: Codable, Hashable, Identifiable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var kind: String
        /// PNG file name inside the pack folder.
        public var imageFile: String
        /// Hotspot and size in points.
        public var hotspotX: Double
        public var hotspotY: Double
        public var width: Double
        public var height: Double

        public init(kind: String, imageFile: String, hotspotX: Double, hotspotY: Double, width: Double, height: Double) {
            self.kind = kind; self.imageFile = imageFile; self.hotspotX = hotspotX; self.hotspotY = hotspotY
            self.width = width; self.height = height
        }
    }

    public static let anyKind = "*"

    public var id: String
    public var name: String
    public var entries: [Entry]
    public var isBuiltin: Bool

    public init(id: String, name: String, entries: [Entry], isBuiltin: Bool = false) {
        self.id = id; self.name = name; self.entries = entries; self.isBuiltin = isBuiltin
    }

    public func entry(for kind: String?) -> Entry? {
        entries.first { $0.kind == kind && kind != nil } ?? entries.first { $0.kind == Self.anyKind }
    }
}

public enum CursorSprites {
    /// Image per telemetry sprite index: the captured macOS cursor, unless the pack replaces its kind.
    public static func resolve(header: Telemetry.Header, packageURL: URL, pack: CursorPack?, packDirectory: URL?) -> [CursorTrack.Sprite] {
        header.cursorSprites.map { captured in
            if let pack, let dir = packDirectory, let entry = pack.entry(for: captured.kind) {
                return CursorTrack.Sprite(
                    imageURL: dir.appending(path: entry.imageFile),
                    hotspot: CGPoint(x: entry.hotspotX, y: entry.hotspotY),
                    size: CGSize(width: entry.width, height: entry.height)
                )
            }
            return CursorTrack.Sprite(
                imageURL: packageURL.appending(path: captured.imageFile),
                hotspot: CGPoint(x: captured.hotspotX, y: captured.hotspotY),
                size: CGSize(width: captured.width, height: captured.height)
            )
        }
    }
}
