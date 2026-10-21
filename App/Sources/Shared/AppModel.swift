import AppKit
import Foundation
import Observation
import SCCapture
import SCExport
import SCProject

/// App-wide state shared by all windows.
@Observable
final class AppModel {
    let library = ProjectLibrary()
    let permissions = PermissionCenter()
    let cursorPacks = CursorPackStore()
    let styles = StyleStore()
    let exports = ExportQueue()
    let recorder: RecordingController
    var lastError: String?

    /// Editors currently open, by package URL, so library actions can go through them.
    @ObservationIgnored private var editors: [URL: WeakEditor] = [:]

    init() {
        recorder = RecordingController(library: library)
        library.reload()
    }

    // MARK: Editors

    /// Returns false if another window already edits this project (the caller should close itself:
    /// two editors saving the same file would overwrite each other).
    @discardableResult
    func register(_ editor: EditorModel) -> Bool {
        let key = editor.packageURL.standardizedFileURL
        if let existing = editors[key]?.model, existing !== editor { return false }
        editors[key] = WeakEditor(model: editor)
        return true
    }

    func unregister(_ editor: EditorModel) {
        let key = editor.packageURL.standardizedFileURL
        if editors[key]?.model === editor { editors[key] = nil }
    }

    private func openEditor(for url: URL) -> EditorModel? {
        editors[url.standardizedFileURL]?.model
    }

    // MARK: Library actions

    /// Creates a project from an existing video file. Returns the new package URL.
    func importVideo(_ url: URL) async -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            return try await library.createProject(name: url.deletingPathExtension().lastPathComponent) { package in
                try await VideoImporter.importVideo(from: url, into: package)
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func rename(_ summary: ProjectSummary, to name: String) {
        if let editor = openEditor(for: summary.url) {
            editor.rename(to: name)
            Task { await editor.flush(); library.reload() }
        } else {
            perform { try library.rename(summary, to: name) }
        }
    }

    func duplicate(_ summary: ProjectSummary) {
        Task {
            await openEditor(for: summary.url)?.flush()
            perform { try library.duplicate(summary) }
        }
    }

    func trash(_ summary: ProjectSummary) {
        perform { try library.trash(summary) }
    }

    func recover(_ url: URL) async -> URL? {
        do {
            return try await library.recover(url)
        } catch {
            lastError = "Couldn't recover the recording: \(error.localizedDescription)"
            return nil
        }
    }

    /// Lets the user pick a `.smoothcursor` package anywhere on disk.
    func chooseProjectFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.smoothCursorProject]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = library.rootURL
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { lastError = error.localizedDescription }
    }
}

private struct WeakEditor {
    weak var model: EditorModel?
}

import UniformTypeIdentifiers

extension UTType {
    static let smoothCursorProject = UTType(exportedAs: "com.smoothcursor.project", conformingTo: .package)
}
