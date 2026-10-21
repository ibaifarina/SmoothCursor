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
if let v = value("--click-volume").flatMap(Double.init) { project.cursor.clickVolume = v }
if let c = value("--crop")?.split(separator: ",").compactMap({ Double($0) }), c.count == 4 {
    project.canvas.crop = UnitRect(x: c[0], y: c[1], width: c[2], height: c[3])
}
if args.contains("--mockup") { project.mockup.device = .phone }
if args.contains("--aspect-wide") { project.canvas.aspect = .wide16x9 }
if args.contains("--auto-camera") { project.cameraClips = MockupCamera.autoShots(duration: project.recording.duration, zooms: project.zooms) }
if args.contains("--motion") { project.motionBlur.enabled = true; project.motionBlur.amount = 0.5 }
for c in project.cameraClips { print(String(format: "shot %-11@ %5.2f–%5.2f", c.preset.label, c.range.start, c.range.end)) }

if args.contains("--transcribe") {
    let video = ProjectPackage.mediaURL(project.recording.videoFile, in: package)
    let captions = try await Transcriber.transcribe(videoURL: video, preferredTrack: nil, locale: Locale(identifier: value("--lang") ?? "en-US")) { print("  …", $0) }
    for c in captions { print(String(format: "  %5.2f–%5.2f  %@", c.range.start, c.range.end, c.text)) }
    exit(0)
}
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
