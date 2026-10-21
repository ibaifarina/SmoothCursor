import AVFoundation
import Foundation
import Observation
import SCCore

public struct ProjectSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var duration: Seconds
    public var sourceKind: RecordingInfo.SourceKind
    public var pixelSize: PixelSize
    public var thumbnailURL: URL?
}

/// All projects in the library folder (default `~/Movies/Smooth Cursor`).
/// The folder is watched, so projects added or removed in Finder show up immediately.
@MainActor
@Observable
public final class ProjectLibrary {
    public let rootURL: URL
    public private(set) var projects: [ProjectSummary] = []
    /// Packages holding media but no document: recordings interrupted by a crash or power loss.
    public private(set) var recoverable: [URL] = []

    /// Packages being recorded into right now; never reported as recoverable.
    @ObservationIgnored private var active: Set<URL> = []
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    public nonisolated static var defaultRoot: URL {
        URL.moviesDirectory.appending(path: "Smooth Cursor", directoryHint: .isDirectory)
    }

    public init(rootURL: URL = ProjectLibrary.defaultRoot) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(url: rootURL) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    public func reload() {
        let root = rootURL
        let active = self.active
        reloadTask?.cancel()
        reloadTask = Task {
            let (found, orphans) = await Task.detached { Self.scan(root) }.value
            guard !Task.isCancelled else { return }
            self.projects = found
            self.recoverable = orphans.filter { !active.contains($0) }
        }
    }

    public func summary(for url: URL) -> ProjectSummary? {
        projects.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    // MARK: Creation

    /// Creates a package and lets `populate` place media into it, then writes the document.
    public func createProject(
        name: String,
        populate: (URL) async throws -> RecordingInfo
    ) async throws -> URL {
        let url = try makePackage(name: name)
        do {
            try finalizeProject(at: url, name: name, recording: try await populate(url))
            return url
        } catch {
            discardPackage(url)
            throw error
        }
    }

    /// Empty package for a recording in progress. Finish with `finalizeProject` or `discardPackage`.
    public func makePackage(name: String) throws -> URL {
        let url = try ProjectPackage.createSkeleton(in: rootURL, name: name)
        active.insert(url)
        return url
    }

    public func finalizeProject(at url: URL, name: String, recording: RecordingInfo) throws {
        try ProjectPackage.write(Project(name: name, recording: recording), to: url)
        active.remove(url)
        reload()
    }

    /// Deletes a package that never became a project (cancelled or failed recording).
    public func discardPackage(_ url: URL) {
        active.remove(url)
        guard url.pathExtension == ProjectPackage.fileExtension,
              !FileManager.default.fileExists(atPath: url.appending(path: ProjectPackage.documentFile).path)
        else { return }
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    // MARK: Management

    /// Renames the project. The package folder keeps its name so open editors stay valid.
    public func rename(_ summary: ProjectSummary, to newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != summary.name else { return }
        var project = try ProjectPackage.read(at: summary.url)
        project.name = name
        project.modifiedAt = .now
        try ProjectPackage.write(project, to: summary.url)
        reload()
    }

    /// Copies the whole package (media included) under a new id and name.
    @discardableResult
    public func duplicate(_ summary: ProjectSummary) throws -> URL {
        let name = "\(summary.name) copy"
        let target = ProjectPackage.uniqueURL(in: rootURL, baseName: ProjectPackage.sanitized(name))
        try FileManager.default.copyItem(at: summary.url, to: target)
        var project = try ProjectPackage.read(at: target)
        project.id = UUID()
        project.name = name
        project.createdAt = .now
        project.modifiedAt = .now
        try ProjectPackage.write(project, to: target)
        reload()
        return target
    }

    /// Moves the package to the Trash (recoverable from Finder).
    public func trash(_ summary: ProjectSummary) throws {
        try FileManager.default.trashItem(at: summary.url, resultingItemURL: nil)
        projects.removeAll { $0.id == summary.id }
    }

    // MARK: Recovery

    /// Turns an interrupted recording into a project. The capture writes fragmented movies,
    /// so everything up to the last fragment is playable. Cursor data is not recoverable.
    @discardableResult
    public func recover(_ url: URL) async throws -> URL {
        let relative = "\(ProjectPackage.mediaDirectory)/screen.mov"
        var info = try await VideoImporter.describe(url.appending(path: relative), relativePath: relative)
        info.sourceKind = .display
        let name = url.deletingPathExtension().lastPathComponent
        try ProjectPackage.write(Project(name: name, recording: info), to: url)
        reload()
        return url
    }

    public func discardRecoverable(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        recoverable.removeAll { $0 == url }
    }

    // MARK: Scanning

    nonisolated static func scan(_ root: URL) -> ([ProjectSummary], [URL]) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var projects: [ProjectSummary] = []
        var orphans: [URL] = []
        for url in urls where url.pathExtension == ProjectPackage.fileExtension {
            guard fm.fileExists(atPath: url.appending(path: ProjectPackage.documentFile).path) else {
                let media = url.appending(path: "\(ProjectPackage.mediaDirectory)/screen.mov")
                if let size = (try? fm.attributesOfItem(atPath: media.path))?[.size] as? Int, size > 0 {
                    orphans.append(url)
                }
                continue
            }
            guard let p = try? ProjectPackage.read(at: url) else { continue }
            let thumb = url.appending(path: ProjectPackage.thumbnailFile)
            projects.append(ProjectSummary(
                id: p.id, url: url, name: p.name, createdAt: p.createdAt, modifiedAt: p.modifiedAt,
                duration: p.recording.duration, sourceKind: p.recording.sourceKind, pixelSize: p.recording.pixelSize,
                thumbnailURL: fm.fileExists(atPath: thumb.path) ? thumb : nil
            ))
        }
        return (projects.sorted { $0.modifiedAt > $1.modifiedAt }, orphans)
    }
}

/// Calls `onChange` (debounced) when the directory's entries change.
final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "smoothcursor.library.watch")

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { source = nil; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source?.cancel() }
}
