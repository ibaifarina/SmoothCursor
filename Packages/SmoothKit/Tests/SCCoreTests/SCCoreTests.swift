import Foundation
import Testing
@testable import SCCore
@testable import SCProject

@Suite struct DocumentTests {
    func sampleProject() -> Project {
        var p = Project(
            name: "Demo",
            recording: RecordingInfo(
                sourceKind: .display, videoFile: "media/screen.mov", telemetryFile: "media/telemetry.sctl",
                pixelSize: PixelSize(width: 3024, height: 1964), displayScale: 2, fps: 60, duration: 14
            )
        )
        p.zooms = [ZoomSegment(range: TimeRange(start: 1, end: 3), focus: .fixed(.center), origin: .auto)]
        p.canvas.background = .gradient(GradientSpec(kind: .mesh, stops: [], meshColors: Array(repeating: .white, count: 9)))
        p.canvas.aspect = .custom(width: 21, height: 9)
        p.cameraClips = [CameraClip(range: TimeRange(start: 0, end: 2), preset: .hero)]
        return p
    }

    @Test func projectRoundTripsThroughPackage() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ProjectPackage.createSkeleton(in: dir, name: "Demo")
        let project = sampleProject()
        try ProjectPackage.write(project, to: url)
        let loaded = try ProjectPackage.read(at: url)
        #expect(loaded.id == project.id)
        #expect(loaded.zooms == project.zooms)
        #expect(loaded.canvas == project.canvas)
        #expect(loaded.cameraClips == project.cameraClips)
    }

    @Test func packageNamesAreUnique() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try ProjectPackage.createSkeleton(in: dir, name: "Demo")
        let b = try ProjectPackage.createSkeleton(in: dir, name: "Demo")
        #expect(a != b)
        #expect(b.lastPathComponent == "Demo 2.smoothcursor")
    }

    @Test func telemetryRoundTrips() throws {
        let t = Telemetry(
            header: .init(targetSize: PixelSize(width: 1512, height: 982), displayScale: 2, cursorSprites: [
                .init(imageFile: "cursors/0.png", hotspotX: 4, hotspotY: 4, width: 17, height: 23, kind: "arrow"),
            ]),
            events: [
                .init(time: 0.0083, kind: .move, x: 100.5, y: 200.25, code: 0),
                .init(time: 0.5, kind: .mouseDown, x: 101, y: 201),
                .init(time: 0.9, kind: .keyDown, x: 0, y: 0, code: 40, modifiers: 0x100000),
            ]
        )
        let decoded = try Telemetry(decoding: try t.encoded())
        #expect(decoded == t)
    }

    @Test func telemetryRejectsGarbage() {
        #expect(throws: TelemetryCodecError.self) { try Telemetry(decoding: Data("nope".utf8)) }
    }
}

@Suite struct MigrationTests {
    @Test func oldDocumentsMissingKeysGetDefaults() throws {
        var p = Project(
            name: "Old",
            recording: RecordingInfo(sourceKind: .display, videoFile: "media/screen.mov", pixelSize: PixelSize(width: 100, height: 100), displayScale: 2, fps: 60, duration: 3)
        )
        p.canvas.padding = 0.2
        var json = try JSONSerialization.jsonObject(with: ProjectPackage.encoder.encode(p)) as! [String: Any]
        // Simulate a document written before these fields existed.
        json["motionBlur"] = nil
        var cursor = json["cursor"] as! [String: Any]
        cursor["clickSound"] = nil
        json["cursor"] = cursor
        let loaded = try ProjectPackage.decodeProject(JSONSerialization.data(withJSONObject: json))
        #expect(loaded.canvas.padding == 0.2)
        #expect(loaded.motionBlur == MotionBlurSettings())
        #expect(loaded.cursor.clickSound == false)
        #expect(loaded.id == p.id)
    }
}
