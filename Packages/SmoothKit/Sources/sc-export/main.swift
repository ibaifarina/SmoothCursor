import Foundation
import SCCore
import SCExport
import SCProject

// Usage: sc-export <package> --out file.mp4 [--codec h264|hevc|proRes422] [--height 1080] [--fps 60] [--gif] [--clicks]
let args = CommandLine.arguments
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
let package = URL(fileURLWithPath: args[1])
var project = try ProjectPackage.read(at: package)
if let c = value("--codec").flatMap(VideoCodec.init(rawValue:)) { project.export.codec = c }
if let h = value("--height").flatMap(Int.init) { project.export.height = h }
if let f = value("--fps").flatMap(Int.init) { project.export.fps = f }
if args.contains("--gif") { project.export.format = .gif }
if args.contains("--clicks") { project.cursor.clickSound = true }

var cursor: CursorTrack?
if let file = project.recording.telemetryFile, let telemetry = try? Telemetry(decoding: Data(contentsOf: package.appending(path: file))) {
    var pack: CursorPack?, dir: URL?
    if case let .customPack(id) = project.cursor.sprite {
        let store = await MainActor.run { CursorPackStore() }
        dir = await MainActor.run { store.directory(for: id) }
        pack = await MainActor.run { store.pack(id: id) }
    }
    cursor = CursorTrack(telemetry: telemetry, settings: project.cursor,
                         sprites: CursorSprites.resolve(header: telemetry.header, packageURL: package, pack: pack, packDirectory: dir),
                         duration: project.recording.duration)
}
let camera = CameraTrack(project: project, cursor: cursor)
let out = URL(fileURLWithPath: value("--out") ?? (project.export.format == .gif ? "out.gif" : "out.mp4"))
let session = ExportSession(request: ExportRequest(project: project, packageURL: package, destination: out, cursor: cursor, camera: camera))
let start = Date()
try await session.run { p in
    if p.framesRendered % 120 == 0 || p.framesRendered == p.totalFrames {
        print(String(format: "  %3.0f%%  %d/%d", p.fraction * 100, p.framesRendered, p.totalFrames))
    }
}
let elapsed = Date().timeIntervalSince(start)
let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
print(String(format: "done in %.1f s (%.2f× realtime for %.1f s of video), %.1f MB → %@",
             elapsed, Cuts.editedDuration(project) / elapsed, Cuts.editedDuration(project), Double(bytes) / 1e6, out.path))
