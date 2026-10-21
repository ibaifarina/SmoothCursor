import Foundation
import SCCore

/// On-disk layout of a `.smoothcursor` package:
///
///     MyProject.smoothcursor/
///       project.json        editable document (autosaved)
///       media/screen.mov    raw capture, never rewritten
///       media/mic.m4a       optional
///       media/telemetry.sctl
///       cursors/*.png       cursor sprites captured at record time
///       thumbnail.jpg
public enum ProjectPackage {
    public static let fileExtension = "smoothcursor"
    public static let documentFile = "project.json"
    public static let mediaDirectory = "media"
    public static let cursorsDirectory = "cursors"
    public static let thumbnailFile = "thumbnail.jpg"

    public static func read(at url: URL) throws -> Project {
        let data = try Data(contentsOf: url.appending(path: documentFile))
        return try decodeProject(data)
    }

    /// Decodes a document, tolerating fields added after it was written: missing keys take the
    /// current defaults (stored JSON is deep-merged over a freshly encoded default project).
    public static func decodeProject(_ data: Data) throws -> Project {
        do {
            return try decoder.decode(Project.self, from: data)
        } catch DecodingError.keyNotFound {
            guard let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recordingJSON = stored["recording"]
            else { throw CocoaError(.fileReadCorruptFile) }
            let recording = try decoder.decode(RecordingInfo.self, from: JSONSerialization.data(withJSONObject: recordingJSON))
            let template = try JSONSerialization.jsonObject(with: encoder.encode(Project(name: "", recording: recording)))
            let merged = deepMerge(template, stored)
            var project = try decoder.decode(Project.self, from: JSONSerialization.data(withJSONObject: merged))
            project.schemaVersion = Project.currentSchemaVersion
            return project
        }
    }

    /// Objects merge key by key; anything else (values, arrays) is taken from `override`.
    /// Single-key objects with different keys are enum cases (`{"image": …}` vs `{"gradient": …}`):
    /// the stored case wins outright instead of being mixed with the default one.
    static func deepMerge(_ base: Any, _ override: Any) -> Any {
        guard var base = base as? [String: Any], let override = override as? [String: Any] else { return override }
        if base.count == 1, override.count == 1, base.keys.first != override.keys.first { return override }
        for (key, value) in override {
            base[key] = base[key].map { deepMerge($0, value) } ?? value
        }
        return base
    }

    /// Atomic write of the document only; media is untouched.
    public static func write(_ project: Project, to url: URL) throws {
        let data = try encoder.encode(project)
        try data.write(to: url.appending(path: documentFile), options: .atomic)
    }

    /// Creates an empty package directory with its subfolders. Returns the package URL.
    public static func createSkeleton(in directory: URL, name: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(in: directory, baseName: sanitized(name))
        try fm.createDirectory(at: url.appending(path: mediaDirectory), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appending(path: cursorsDirectory), withIntermediateDirectories: true)
        return url
    }

    public static func mediaURL(_ relativePath: String, in package: URL) -> URL {
        package.appending(path: relativePath)
    }

    static func uniqueURL(in directory: URL, baseName: String) -> URL {
        var candidate = directory.appending(path: "\(baseName).\(fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(baseName) \(n).\(fileExtension)")
            n += 1
        }
        return candidate
    }

    static func sanitized(_ name: String) -> String {
        let cleaned = name.replacing(/[\/:]/, with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
