import Foundation
import Observation
import SCCore

/// Saved looks in `~/Library/Application Support/Smooth Cursor/Styles.json`.
/// The default style is applied to every new recording.
@MainActor
@Observable
public final class StyleStore {
    struct File: Codable {
        var presets: [StylePreset] = []
        var defaultID: UUID?
    }

    public private(set) var presets: [StylePreset] = []
    public private(set) var defaultID: UUID?
    private let url: URL

    public nonisolated static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Smooth Cursor/Styles.json")
    }

    public init(url: URL = StyleStore.defaultURL) {
        self.url = url
        let file = Self.read(url)
        presets = file.presets
        defaultID = file.defaultID
    }

    public var defaultPreset: StylePreset? { presets.first { $0.id == defaultID } }

    @discardableResult
    public func save(name: String, from project: Project) -> StylePreset {
        let preset = StylePreset(name: name, from: project)
        presets.append(preset)
        write()
        return preset
    }

    /// Replaces a preset's look with the project's, keeping its name and id.
    public func overwrite(_ id: UUID, from project: Project) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        var preset = StylePreset(name: presets[i].name, from: project)
        preset.id = id
        presets[i] = preset
        write()
    }

    public func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if defaultID == id { defaultID = nil }
        write()
    }

    public func setDefault(_ id: UUID?) {
        defaultID = id
        write()
    }

    /// The default preset, read straight from disk (usable off the main actor).
    public nonisolated static func loadDefault(url: URL = StyleStore.defaultURL) -> StylePreset? {
        let file = read(url)
        return file.presets.first { $0.id == file.defaultID }
    }

    private nonisolated static func read(_ url: URL) -> File {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(presets: presets, defaultID: defaultID)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
