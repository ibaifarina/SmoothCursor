import AppKit
import CoreGraphics
import ImageIO
import Observation
import SCCore
import UniformTypeIdentifiers

/// Cursor packs in `~/Library/Application Support/Smooth Cursor/Cursor Packs`.
/// Built-in packs are drawn in code at high resolution on first launch.
@MainActor
@Observable
public final class CursorPackStore {
    public let rootURL: URL
    public private(set) var packs: [CursorPack] = []

    public nonisolated static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Smooth Cursor/Cursor Packs", directoryHint: .isDirectory)
    }

    public init(rootURL: URL = CursorPackStore.defaultRoot) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        BuiltinCursors.install(into: rootURL)
        reload()
    }

    public func directory(for id: String) -> URL { rootURL.appending(path: id, directoryHint: .isDirectory) }

    public func pack(id: String) -> CursorPack? { packs.first { $0.id == id } }

    public func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        packs = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appending(path: "pack.json")) else { return nil }
            return try? JSONDecoder().decode(CursorPack.self, from: data)
        }
        .sorted { ($0.isBuiltin ? 0 : 1, $0.name) < ($1.isBuiltin ? 0 : 1, $1.name) }
    }

    /// Creates a pack from one image. `hotspot` is in image pixels; `pointHeight` sets its on-screen size.
    @discardableResult
    public func importImage(_ imageURL: URL, name: String, kind: String, hotspot: CGPoint, pointHeight: Double) throws -> CursorPack {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        let id = "custom-\(UUID().uuidString.prefix(8))"
        let dir = directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try BuiltinCursors.writePNG(image, to: dir.appending(path: "cursor.png"))
        let scale = pointHeight / Double(image.height)
        let pack = CursorPack(id: id, name: name, entries: [
            .init(kind: kind, imageFile: "cursor.png", hotspotX: hotspot.x * scale, hotspotY: hotspot.y * scale,
                  width: Double(image.width) * scale, height: pointHeight),
        ])
        try JSONEncoder().encode(pack).write(to: dir.appending(path: "pack.json"))
        reload()
        return pack
    }

    public func delete(_ pack: CursorPack) throws {
        guard !pack.isBuiltin else { return }
        try FileManager.default.trashItem(at: directory(for: pack.id), resultingItemURL: nil)
        reload()
    }
}

/// Vector cursors rasterized at 16× so they stay crisp at any zoom.
enum BuiltinCursors {
    static let version = 1
    static let scale = 16.0

    static func install(into root: URL) {
        install(root: root, id: "builtin-white", name: "White", kind: "arrow", size: CGSize(width: 14, height: 21), hotspot: CGPoint(x: 1.5, y: 1.5)) { ctx in
            arrowPath(in: ctx, fill: .white, stroke: CGColor(gray: 0, alpha: 1))
        }
        install(root: root, id: "builtin-dot", name: "Dot", kind: CursorPack.anyKind, size: CGSize(width: 28, height: 28), hotspot: CGPoint(x: 14, y: 14)) { ctx in
            let r = CGRect(x: 4, y: 4, width: 20, height: 20)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
            ctx.fillEllipse(in: r.insetBy(dx: -2, dy: -2))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: r)
        }
    }

    private static func install(root: URL, id: String, name: String, kind: String, size: CGSize, hotspot: CGPoint, draw: (CGContext) -> Void) {
        let dir = root.appending(path: id, directoryHint: .isDirectory)
        let manifest = dir.appending(path: "pack.json")
        if let data = try? Data(contentsOf: manifest), let existing = try? JSONDecoder().decode(CursorPack.self, from: data),
           existing.name == name, FileManager.default.fileExists(atPath: dir.appending(path: "cursor.png").path) { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // Draw in points, origin top-left.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx)
        guard let image = ctx.makeImage() else { return }
        try? writePNG(image, to: dir.appending(path: "cursor.png"))
        let pack = CursorPack(id: id, name: name, entries: [
            .init(kind: kind, imageFile: "cursor.png", hotspotX: hotspot.x, hotspotY: hotspot.y, width: size.width, height: size.height),
        ], isBuiltin: true)
        try? JSONEncoder().encode(pack).write(to: manifest)
    }

    /// Classic arrow silhouette, 14×21 pt box, tip at (1.5, 1.5).
    private static func arrowPath(in ctx: CGContext, fill: CGColor, stroke: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 1.5, y: 1.5))
        p.addLine(to: CGPoint(x: 1.5, y: 16.5))
        p.addLine(to: CGPoint(x: 5.2, y: 13.1))
        p.addLine(to: CGPoint(x: 7.6, y: 18.9))
        p.addLine(to: CGPoint(x: 10.1, y: 17.9))
        p.addLine(to: CGPoint(x: 7.7, y: 12.2))
        p.addLine(to: CGPoint(x: 12.6, y: 12.2))
        p.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.6), blur: 1.2, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(p)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(p)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(1.1)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
