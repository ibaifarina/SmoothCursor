import AppKit
import Observation
import SCCore
import SCProject
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case background, cursor, zoom, mockup, export
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .background: "photo"
        case .cursor: "cursorarrow"
        case .zoom: "plus.magnifyingglass"
        case .mockup: "iphone"
        case .export: "square.and.arrow.up"
        }
    }

    var title: String { rawValue.capitalized }
}

/// State of one open project. Every mutation goes through `update` so it is autosaved and undoable.
@Observable
final class EditorModel {
    let packageURL: URL
    let autosaver: Autosaver
    private(set) var project: Project?
    var loadError: String?
    var inspectorTab: InspectorTab = .background
    var playhead: Seconds = 0
    /// First frame, shown on the placeholder canvas until the Metal preview exists (step 3).
    var posterFrame: CGImage?

    @ObservationIgnored weak var undoManager: UndoManager?
    /// Consecutive edits with the same name inside this window become one undo step (slider drags).
    @ObservationIgnored private var lastEdit: (name: String, at: Date)?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    private static let coalesceWindow: TimeInterval = 0.8

    init(packageURL: URL) {
        self.packageURL = packageURL
        autosaver = Autosaver(packageURL: packageURL)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaver.flushSynchronously() }
        }
    }

    func load() async {
        do {
            let url = packageURL
            project = try await Task.detached { try ProjectPackage.read(at: url) }.value
            await loadPosterFrame()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Applies an edit. `coalesce` merges rapid repeats of the same action into one undo step.
    func update(_ actionName: String, coalesce: Bool = false, _ mutate: (inout Project) -> Void) {
        guard var next = project else { return }
        let previous = next
        mutate(&next)
        guard next != previous else { return }

        let now = Date()
        let merges = coalesce && lastEdit?.name == actionName
            && now.timeIntervalSince(lastEdit!.at) < Self.coalesceWindow
        lastEdit = (actionName, now)
        apply(next, actionName: actionName, undoTo: merges ? nil : previous)
    }

    /// Binding into the project for inspector controls. Continuous controls coalesce undo by default.
    func binding<V>(_ keyPath: WritableKeyPath<Project, V>, _ actionName: String, coalesce: Bool = true) -> Binding<V> {
        Binding(
            get: { self.project![keyPath: keyPath] },
            set: { value in self.update(actionName, coalesce: coalesce) { $0[keyPath: keyPath] = value } }
        )
    }

    func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update("Rename") { $0.name = trimmed }
    }

    func flush() async {
        await autosaver.flush()
    }

    func close() async {
        await autosaver.flush()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    private func apply(_ next: Project, actionName: String, undoTo previous: Project?) {
        project = next
        autosaver.schedule(next)
        guard let previous, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.lastEdit = nil
            // The state at undo time (after any coalesced edits) becomes the redo target.
            model.apply(previous, actionName: actionName, undoTo: model.project)
        }
        undoManager.setActionName(actionName)
    }

    private func loadPosterFrame() async {
        guard let project else { return }
        posterFrame = await Thumbnailer.frame(of: ProjectPackage.mediaURL(project.recording.videoFile, in: packageURL), at: 0)
        _ = await Thumbnailer.ensureThumbnail(for: packageURL)
    }
}
