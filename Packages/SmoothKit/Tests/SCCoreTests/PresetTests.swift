import Foundation
import Testing
@testable import SCCore

struct PresetTests {
    func project() -> Project {
        Project(name: "Test", recording: RecordingInfo(
            sourceKind: .display, videoFile: "media/screen.mov",
            pixelSize: PixelSize(width: 1920, height: 1080), displayScale: 2, fps: 60, duration: 10
        ))
    }

    @Test func appliesOnlyChosenGroups() {
        var source = project()
        source.canvas.padding = 0.2
        source.canvas.background = .color(.black)
        source.cursor.scale = 3
        source.export.fps = 30
        let preset = StylePreset(name: "P", from: source, groups: [.background, .cursor])

        var target = project()
        target.canvas.crop = UnitRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        preset.apply(to: &target)
        #expect(target.canvas.background == .color(.black))
        #expect(target.cursor.scale == 3)
        #expect(target.canvas.padding == CanvasSettings().padding)
        #expect(target.export.fps == ExportSettings().fps)
        #expect(target.canvas.crop == UnitRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
    }

    @Test func presetsWithoutGroupsApplyAllButThePhone() throws {
        var source = project()
        source.mockup.device = .phone
        source.canvas.padding = 0.2
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StylePreset(name: "Old", from: source))) as! [String: Any]
        json["groups"] = nil
        json["mockup"] = nil
        let old = try JSONDecoder().decode(StylePreset.self, from: JSONSerialization.data(withJSONObject: json))
        var target = project()
        old.apply(to: &target)
        #expect(target.canvas.padding == 0.2)
        #expect(!target.mockup.isEnabled)
    }
}
