import AVFoundation
import CoreGraphics
import Foundation
import SCCapture
import SCCore

// Usage: sc-record [--seconds N] [--fps N] [--codec hevc|h264|proRes422] [--area] [--window ID] [--no-audio] [--pause]
let args = CommandLine.arguments
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }

var settings = RecordingSettings()
settings.fps = Int(value("--fps") ?? "60") ?? 60
settings.codec = VideoCodec(rawValue: value("--codec") ?? "hevc") ?? .hevc
settings.captureSystemAudio = !args.contains("--no-audio")
let display = CGMainDisplayID()
if let id = value("--window").flatMap(UInt32.init) {
    settings.target = .window(id: id)
} else if args.contains("--area") {
    settings.target = .area(displayID: display, x: 100, y: 100, width: 801, height: 501)
} else {
    settings.target = .display(id: display)
}
let seconds = Double(value("--seconds") ?? "3") ?? 3

let package = FileManager.default.temporaryDirectory.appending(path: "sc-record-\(UUID().uuidString.prefix(6)).smoothcursor")
try FileManager.default.createDirectory(at: package.appending(path: "media"), withIntermediateDirectories: true)

let engine = ScreenCaptureEngine()
engine.onFailure = { print("FAILURE:", $0) }
try await engine.start(settings: settings, packageURL: package)
print("recording \(seconds)s → \(package.path)")
if args.contains("--pause") {
    try await Task.sleep(for: .seconds(seconds / 3)); engine.pause()
    try await Task.sleep(for: .seconds(seconds / 3)); engine.resume()
    try await Task.sleep(for: .seconds(seconds / 3))
} else {
    try await Task.sleep(for: .seconds(seconds))
}
let result = try await engine.stop()
let r = result.recording
print("size \(r.pixelSize.width)x\(r.pixelSize.height) scale \(r.displayScale) duration \(String(format: "%.3f", r.duration))s frames \(result.framesWritten) dropped \(result.framesDropped)")
let asset = AVURLAsset(url: package.appending(path: r.videoFile))
for track in try await asset.load(.tracks) {
    let type = track.mediaType; let range = try await track.load(.timeRange)
    print("track \(type.rawValue) \(String(format: "%.3f", range.duration.seconds))s")
}
if let t = result.telemetry {
    let kinds = Dictionary(grouping: t.events, by: \.kind).mapValues(\.count)
    print("telemetry events \(t.events.count) \(kinds) sprites \(t.header.cursorSprites.map { $0.kind ?? "?" })")
}
