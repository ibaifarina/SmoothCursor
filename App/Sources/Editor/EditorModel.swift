import AppKit
import Observation
import SCCore
import SCProject
import SCRender
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
    private(set) var playback: PlaybackController?
    var isCropping = false
    var cropLock: CropLock = .free
    /// True while a text field is being edited, so single-key shortcuts (Space, arrows) stay out of the way.
    var isEditingText = false
    /// Cursor motion and look, rebuilt whenever cursor settings or the cursor pack change.
    private(set) var cursorTrack: CursorTrack?
    private(set) var telemetry: Telemetry?
    @ObservationIgnored var cursorPacks: CursorPackStore?

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
            let loaded = try await Task.detached { try ProjectPackage.read(at: url) }.value
            if let file = loaded.recording.telemetryFile {
                let telemetryURL = url.appending(path: file)
                telemetry = try? await Task.detached { try Telemetry(decoding: Data(contentsOf: telemetryURL)) }.value
            }
            project = loaded
            rebuildCursorTrack()
            playback = PlaybackController(
                url: ProjectPackage.mediaURL(loaded.recording.videoFile, in: url),
                duration: loaded.recording.duration, fps: loaded.recording.fps
            )
            #if DEBUG
            if ProcessInfo.processInfo.environment["SC_AUTOPLAY"] != nil { playback?.play() }
            if ProcessInfo.processInfo.environment["SC_CROP"] != nil { isCropping = true }
            if let tab = ProcessInfo.processInfo.environment["SC_TAB"].flatMap(InspectorTab.init(rawValue:)) { inspectorTab = tab }
            #endif
            _ = await Thumbnailer.ensureThumbnail(for: url)
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
        playback?.invalidate()
        await autosaver.flush()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// Re-resolves sprites (e.g. after importing a pack) and re-simulates the cursor path.
    func rebuildCursorTrack() {
        guard let project, let telemetry else { cursorTrack = nil; return }
        var pack: CursorPack?
        var directory: URL?
        if case let .customPack(id) = project.cursor.sprite, let store = cursorPacks {
            pack = store.pack(id: id)
            directory = store.directory(for: id)
        }
        let sprites = CursorSprites.resolve(header: telemetry.header, packageURL: packageURL, pack: pack, packDirectory: directory)
        cursorTrack = CursorTrack(telemetry: telemetry, settings: project.cursor, sprites: sprites, duration: project.recording.duration)
    }

    private func apply(_ next: Project, actionName: String, undoTo previous: Project?) {
        let cursorChanged = project?.cursor != next.cursor
        project = next
        if cursorChanged { rebuildCursorTrack() }
        autosaver.schedule(next)
        guard let previous, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.lastEdit = nil
            // The state at undo time (after any coalesced edits) becomes the redo target.
            model.apply(previous, actionName: actionName, undoTo: model.project)
        }
        undoManager.setActionName(actionName)
    }
}
