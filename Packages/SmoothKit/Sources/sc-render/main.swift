import CoreGraphics
import Foundation
import ImageIO
import SCCore
import SCProject
import SCRender
import UniformTypeIdentifiers

// Usage: sc-render <package.smoothcursor> [--time S] [--height H] [--out file.png]
//        [--background color|linear|radial|angular|mesh] [--aspect 16:9|9:16|1:1|4:5]
//        [--zoom SCALE [--focus x,y|cursor]] [--crop x,y,w,h] [--padding P] [--radius R] [--crop-mode]
//        [--cursor-scale S] [--pack builtin-white|builtin-dot] [--click ripple|pulse|press|none] [--no-cursor]
let args = CommandLine.arguments
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
func numbers(_ s: String) -> [Double] { s.split(separator: ",").compactMap { Double($0) } }

guard args.count > 1 else { print("usage: sc-render <package> [options]"); exit(1) }
let package = URL(fileURLWithPath: args[1])
var project = try ProjectPackage.read(at: package)
let time = Double(value("--time") ?? "1") ?? 1

switch value("--background") {
case "color": project.canvas.background = .color(RGBAColor(hex: 0xF4F4F5))
case "linear": project.canvas.background = .gradient(.sunset)
case "radial": project.canvas.background = .gradient(GradientSpec(kind: .radial, stops: [.init(0, RGBAColor(hex: 0x6366F1)), .init(1, RGBAColor(hex: 0x0F172A))]))
case "angular": project.canvas.background = .gradient(GradientSpec(kind: .angular, stops: [.init(0, RGBAColor(hex: 0xFF6A1F)), .init(0.5, RGBAColor(hex: 0xFF3D6E)), .init(1, RGBAColor(hex: 0xFF6A1F))], angle: -90))
case "mesh": project.canvas.background = .gradient(GradientSpec(kind: .mesh, stops: [], meshColors: [
    RGBAColor(hex: 0xA5F3FC), RGBAColor(hex: 0xC4B5FD), RGBAColor(hex: 0xFBCFE8),
    RGBAColor(hex: 0x93C5FD), RGBAColor(hex: 0xE0E7FF), RGBAColor(hex: 0xFDE68A),
    RGBAColor(hex: 0xBAE6FD), RGBAColor(hex: 0xFBCFE8), RGBAColor(hex: 0xFED7AA),
]))
default: break
}
switch value("--aspect") {
case "16:9": project.canvas.aspect = .wide16x9
case "9:16": project.canvas.aspect = .vertical9x16
case "1:1": project.canvas.aspect = .square
case "4:5": project.canvas.aspect = .portrait4x5
default: break
}
if let image = value("--image") {
    let path = try BackgroundImages.importImage(URL(fileURLWithPath: image), into: FileManager.default.temporaryDirectory.appending(path: "sc-render-bg"))
    project.canvas.background = .image(ImageBackground(source: .projectFile(relativePath: path), blur: Double(value("--blur") ?? "0") ?? 0))
}
if let g = value("--grain").flatMap(Double.init) { project.canvas.backgroundNoise = g }
if let m = value("--motion").flatMap(Double.init) { project.motionBlur.enabled = m > 0; project.motionBlur.amount = m }
if let p = value("--padding").flatMap(Double.init) { project.canvas.padding = p }
if let r = value("--radius").flatMap(Double.init) { project.canvas.cornerRadius = r }
if let c = value("--crop").map(numbers), c.count == 4 { project.canvas.crop = UnitRect(x: c[0], y: c[1], width: c[2], height: c[3]) }
if let z = value("--zoom").flatMap(Double.init) {
    let focus: ZoomSegment.Focus = value("--focus") == "cursor"
        ? .followCursor(deadZone: 0)
        : .fixed({ let f = value("--focus").map(numbers) ?? [0.5, 0.5]; return UnitPoint2D(x: f[0], y: f[1]) }())
    project.zooms = [ZoomSegment(range: TimeRange(start: 0, end: project.recording.duration), scale: z,
                                 focus: focus, transitionIn: 0, transitionOut: 0)]
}
if let c = value("--cursor-scale").flatMap(Double.init) { project.cursor.scale = c }
if let e = value("--click").flatMap(CursorSettings.ClickEffect.init(rawValue:)) { project.cursor.clickEffect = e }
if args.contains("--no-cursor") { project.cursor.visible = false }
if let pack = value("--pack") { project.cursor.sprite = .customPack(id: pack) }

var track: CursorTrack?
if let file = project.recording.telemetryFile,
   let telemetry = try? Telemetry(decoding: Data(contentsOf: package.appending(path: file))) {
    var pack: CursorPack?
    var packDir: URL?
    if case let .customPack(id) = project.cursor.sprite {
        let dir = await MainActor.run { CursorPackStore().directory(for: id) }
        packDir = dir
        pack = (try? Data(contentsOf: dir.appending(path: "pack.json"))).flatMap { try? JSONDecoder().decode(CursorPack.self, from: $0) }
    }
    let sprites = CursorSprites.resolve(header: telemetry.header, packageURL: package, pack: pack, packDirectory: packDir)
    track = CursorTrack(telemetry: telemetry, settings: project.cursor, sprites: sprites, duration: project.recording.duration)
    let clickTimes = telemetry.events.filter { $0.kind == .mouseDown }.map { String(format: "%.3f", $0.time) }
    print("telemetry: \(telemetry.events.count) events, clicks at \(clickTimes)")
    if args.contains("--auto") {
        project.zooms = []
        AutoZoom.regenerate(&project, telemetry: telemetry)
        for z in project.zooms { print(String(format: "auto zoom %.2f–%.2f s at %.2f×", z.range.start, z.range.end, z.scale)) }
    }
}

let cameraTrack = CameraTrack(project: project, cursor: track)
let height = Double(value("--height") ?? "1080") ?? 1080
let aspect = args.contains("--crop-mode") ? project.recording.pixelSize.aspect : FrameLayout.outputAspect(for: project)
let size = CGSize(width: (height * aspect).rounded(), height: height)
let layout = args.contains("--crop-mode")
    ? FrameLayout.cropEditing(project: project, outputSize: size)
    : FrameLayout.make(project: project, time: time, outputSize: size, cursor: track, camera: cameraTrack)

guard let context = MetalContext.shared else { print("no Metal"); exit(1) }
let renderer = try OfflineRenderer(context: context)
renderer.compositor.imageResolver = { source in
    if case let .projectFile(path) = source {
        return path.hasPrefix("media/background-") && !FileManager.default.fileExists(atPath: package.appending(path: path).path)
            ? FileManager.default.temporaryDirectory.appending(path: "sc-render-bg").appending(path: path)
            : package.appending(path: path)
    }
    return nil
}
let source = try await VideoFrameReader.pixelBuffer(of: ProjectPackage.mediaURL(project.recording.videoFile, in: package), at: time)
let start = Date()
let motion = args.contains("--crop-mode") ? nil : FrameLayout.motionBlur(
    project: project, time: time, outputSize: size, cursor: track, camera: cameraTrack,
    frameDuration: 1 / Double(project.export.fps), quality: .export
)
if let motion { print("motion blur: camera \(motion.hasCameraMotion), cursor samples \(motion.cursors.count)") }
let image = try renderer.render(layout: layout, source: source, motion: motion)
let elapsed = Date().timeIntervalSince(start)

let out = URL(fileURLWithPath: value("--out") ?? "frame.png")
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("rendered \(Int(size.width))x\(Int(size.height)) in \(String(format: "%.1f", elapsed * 1000)) ms (incl. pipeline warmup) camera scale \(String(format: "%.2f", layout.camera.scale)) → \(out.path)")
