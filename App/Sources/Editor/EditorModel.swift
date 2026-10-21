import AppKit
import AVFoundation
import Observation
import SCCore
import SCProject
import SCRender
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case background, cursor, zoom, mockup, overlays, presets, export
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .background: "photo"
        case .cursor: "cursorarrow"
        case .zoom: "plus.magnifyingglass"
        case .mockup: "iphone"
        case .overlays: "text.bubble"
        case .presets: "square.stack.3d.up"
        case .export: "square.and.arrow.up"
        }
    }

    var title: String {
        switch self {
        case .mockup: "Device"
        default: rawValue.capitalized
        }
    }
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
    /// Camera motion from the zoom segments; rebuilt when zooms, framing or the cursor change.
    private(set) var cameraTrack: CameraTrack?
    private(set) var telemetry: Telemetry?
    @ObservationIgnored var cursorPacks: CursorPackStore?

    // Timeline
    var selectedZooms: Set<UUID> = []
    var selectedShots: Set<UUID> = []
    var selectedBlurs: Set<UUID> = []
    var selectedClip: Int?
    /// Timeline magnification: 1 = whole recording fits the width.
    var timelineZoom = 1.0
    private(set) var waveform: [Float] = []
    /// While true, a click on the canvas sets the fixed focus of the selected zooms.
    var isPickingFocus = false
    /// While true, dragging on the canvas adds a blur region.
    var isDrawingRedaction = false
    private(set) var keystrokeTrack: KeystrokeTrack?
    /// Names of the recording's audio tracks, in order.
    private(set) var audioTrackNames: [String] = []
    /// Caption generation status shown in the inspector (nil when idle).
    var captionStatus: String?
    var captionError: String?

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
            // First open: place zooms automatically, and put phone recordings into a 3D phone
            // with ready-made camera shots (not undoable edits).
            if !loaded.autoZoomGenerated {
                var generated = loaded
                if let telemetry { AutoZoom.regenerate(&generated, telemetry: telemetry) }
                generated.autoZoomGenerated = true
                let phoneLike = [.iPhone, .simulator].contains(loaded.recording.sourceKind)
                    || (loaded.recording.sourceKind == .imported && FrameLayout.croppedSourceAspect(loaded) < 0.8)
                if phoneLike {
                    generated.mockup.device = .phone
                    generated.cameraClips = MockupCamera.autoShots(duration: generated.recording.duration, zooms: generated.zooms)
                }
                project = generated
                autosaver.schedule(generated)
            }
            rebuildCursorTrack()
            rebuildCameraTrack()
            let videoURL = ProjectPackage.mediaURL(loaded.recording.videoFile, in: url)
            Task { [weak self] in
                let peaks = (try? await Task.detached(priority: .utility) { try await Waveform.peaks(of: videoURL) }.value) ?? []
                self?.waveform = peaks
            }
            playback = PlaybackController(
                url: ProjectPackage.mediaURL(loaded.recording.videoFile, in: url),
                cameraURL: loaded.recording.cameraFile.map { url.appending(path: $0) },
                duration: loaded.recording.duration, fps: loaded.recording.fps
            )
            rebuildKeystrokeTrack()
            await loadAudioTrackNames()
            syncVolumes()
            syncPlaybackCuts()
            #if DEBUG
            if ProcessInfo.processInfo.environment["SC_AUTOPLAY"] != nil { playback?.play() }
            if ProcessInfo.processInfo.environment["SC_CROP"] != nil { isCropping = true }
            if let tab = ProcessInfo.processInfo.environment["SC_TAB"].flatMap(InspectorTab.init(rawValue:)) { inspectorTab = tab }
            if ProcessInfo.processInfo.environment["SC_SELECT_ZOOM"] != nil, let id = project?.zooms.first?.id { select(zoom: id) }
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

    func rebuildCameraTrack() {
        guard let project else { cameraTrack = nil; return }
        cameraTrack = project.zooms.isEmpty ? nil : CameraTrack(project: project, cursor: cursorTrack)
    }

    private func rebuildKeystrokeTrack() {
        guard let project, let telemetry else { keystrokeTrack = nil; return }
        keystrokeTrack = KeystrokeTrack(telemetry: telemetry, settings: project.keystrokes)
    }

    /// Whether the recording has any keyboard data (needs Accessibility while recording).
    var hasKeyData: Bool { telemetry?.events.contains { $0.kind == .keyDown } ?? false }

    private func syncVolumes() {
        guard let project else { return }
        playback?.setVolumes(audioTrackNames.indices.map { project.audio.volume(track: $0) })
    }

    private func loadAudioTrackNames() async {
        guard let project else { return }
        if let known = project.recording.audioTracks {
            audioTrackNames = known.map(\.name)
            return
        }
        let asset = AVURLAsset(url: ProjectPackage.mediaURL(project.recording.videoFile, in: packageURL))
        let count = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        audioTrackNames = count == 1 ? ["Audio"] : (0..<count).map { "Audio \($0 + 1)" }
    }

    // MARK: Extras

    /// Short message shown over the canvas for a moment (results of one-shot actions).
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Removes long stretches where nothing happens (no movement, input or sound).
    func trimIdle() {
        guard let project else { return }
        let kept = IdleTrim.keptRanges(project: project, telemetry: telemetry, peaks: waveform)
        let removed = Cuts.editedDuration(project) - kept.map(\.duration).reduce(0, +)
        guard removed > 0.2 else { showToast("No idle parts found"); return }
        update("Trim Idle Parts") { $0.cuts = kept }
        showToast(String(format: "Removed %.1f s of idle time · ⌘Z to undo", removed))
    }

    func generateCaptions(language: String) async {
        guard let project else { return }
        captionError = nil
        captionStatus = "Starting…"
        let video = ProjectPackage.mediaURL(project.recording.videoFile, in: packageURL)
        // Narration usually lives on the microphone track.
        let mic = project.recording.audioTracks?.firstIndex { $0.kind == .microphone }
        do {
            let segments = try await Transcriber.transcribe(videoURL: video, preferredTrack: mic, locale: Locale(identifier: language)) { status in
                Task { @MainActor in self.captionStatus = status }
            }
            update("Generate Captions") {
                $0.captionSegments = segments
                $0.captions.enabled = true
                $0.captions.language = language
            }
            captionStatus = nil
            if segments.isEmpty { captionError = "No speech was found." }
        } catch {
            captionStatus = nil
            captionError = error.localizedDescription
        }
    }

    /// Starts (or cancels) drawing a blur region on the canvas.
    func toggleBlurDrawing() {
        isPickingFocus = false
        isDrawingRedaction.toggle()
    }

    /// Adds a blur region starting at the playhead, in free space on the blur track when there is some.
    func addRedaction(_ rect: UnitRect) {
        guard let project else { return }
        let duration = project.recording.duration
        let t = min(playheadTime, max(duration - TimelineEdits.minDuration, 0))
        let range = TimelineEdits.freeRange(at: t, in: project.redactions, duration: duration, length: 4)
            ?? TimeRange(start: t, end: min(t + 4, duration))
        let region = RedactRegion(range: range, rect: rect)
        update("Add Blur Region") { $0.redactions.append(region) }
        isDrawingRedaction = false
        select(blur: region.id)
    }

    func select(blur id: UUID, extend: Bool = false) {
        selectedClip = nil
        selectedZooms = []
        selectedShots = []
        if extend {
            if selectedBlurs.contains(id) { selectedBlurs.remove(id) } else { selectedBlurs.insert(id) }
        } else {
            selectedBlurs = [id]
        }
        inspectorTab = .overlays
    }

    func updateSelectedBlurs(_ actionName: String, _ change: @escaping (inout RedactRegion) -> Void) {
        let ids = selectedBlurs
        guard !ids.isEmpty else { return }
        update(actionName) { $0.redactions = TimelineEdits.update($0.redactions, ids: ids, change) }
    }

    private func syncPlaybackCuts() {
        guard let project else { return }
        playback?.keptRanges = project.cuts.isEmpty ? [] : Cuts.kept(project)
    }

    // MARK: Timeline actions

    var playheadTime: Seconds { playback?.time ?? 0 }

    /// The timeline shows camera shots while the 3D phone is on, zooms otherwise.
    var showsShots: Bool { project?.mockup.isEnabled ?? false }

    /// Whether there's room at the playhead for a new shot (it isn't inside one).
    var canAddShot: Bool {
        guard let project else { return false }
        return TimelineEdits.freeRange(at: playheadTime, in: project.cameraClips, duration: project.recording.duration, length: 4) != nil
    }

    var canAddZoom: Bool {
        guard let project else { return false }
        return TimelineEdits.freeRange(at: playheadTime, in: project.zooms, duration: project.recording.duration, length: 2.5) != nil
    }

    /// Adds a zoom, or a camera shot while the 3D phone is on, at the playhead.
    func addMotionAtPlayhead() {
        if showsShots { addShot(at: playheadTime) } else { addZoomAtPlayhead() }
    }

    func addZoomAtPlayhead() {
        guard let project, let zoom = ZoomEdits.insertion(at: playheadTime, in: project.zooms, duration: project.recording.duration,
                                                                 staysInRecording: project.autoZoom.staysInRecording) else { return }
        update("Add Zoom") { $0.zooms.append(zoom) }
        select(zoom: zoom.id)
    }

    func addZoom(at time: Seconds) {
        guard let project, let zoom = ZoomEdits.insertion(at: time, in: project.zooms, duration: project.recording.duration,
                                                                 staysInRecording: project.autoZoom.staysInRecording) else { return }
        update("Add Zoom") { $0.zooms.append(zoom) }
        select(zoom: zoom.id)
    }

    func select(zoom id: UUID, extend: Bool = false) {
        selectedClip = nil
        selectedShots = []
        selectedBlurs = []
        if extend {
            if selectedZooms.contains(id) { selectedZooms.remove(id) } else { selectedZooms.insert(id) }
        } else {
            selectedZooms = [id]
        }
        inspectorTab = .zoom
    }

    /// Selects every item on the motion track (zooms, or shots while the 3D phone is on).
    func selectAllMotion() {
        selectedClip = nil
        selectedBlurs = []
        if showsShots {
            selectedZooms = []
            selectedShots = Set(project?.cameraClips.map(\.id) ?? [])
            if !selectedShots.isEmpty { inspectorTab = .mockup }
        } else {
            selectedShots = []
            selectedZooms = Set(project?.zooms.map(\.id) ?? [])
            if !selectedZooms.isEmpty { inspectorTab = .zoom }
        }
    }

    func select(clip index: Int) {
        selectedZooms = []
        selectedShots = []
        selectedBlurs = []
        selectedClip = index
    }

    func clearSelection() {
        isDrawingRedaction = false
        selectedZooms = []
        selectedShots = []
        selectedBlurs = []
        selectedClip = nil
        isPickingFocus = false
    }

    /// Whether Delete would remove something. The only clip can't be deleted.
    var canDelete: Bool {
        guard let project else { return false }
        if !selectedShots.isEmpty || !selectedZooms.isEmpty || !selectedBlurs.isEmpty { return true }
        return selectedClip != nil && Cuts.kept(project).count > 1
    }

    func updateSelectedZooms(_ actionName: String, coalesce: Bool = false, _ change: @escaping (inout ZoomSegment) -> Void) {
        let ids = selectedZooms
        guard !ids.isEmpty else { return }
        update(actionName, coalesce: coalesce) { $0.zooms = ZoomEdits.update($0.zooms, ids: ids, change) }
    }

    func deleteSelection() {
        if !selectedBlurs.isEmpty {
            let ids = selectedBlurs
            update(ids.count == 1 ? "Delete Blur Region" : "Delete Blur Regions") { $0.redactions.removeAll { ids.contains($0.id) } }
            selectedBlurs = []
        } else if !selectedShots.isEmpty {
            let ids = selectedShots
            update(ids.count == 1 ? "Delete Shot" : "Delete Shots") { $0.cameraClips.removeAll { ids.contains($0.id) } }
            selectedShots = []
        } else if !selectedZooms.isEmpty {
            let ids = selectedZooms
            update(ids.count == 1 ? "Delete Zoom" : "Delete Zooms") { $0.zooms.removeAll { ids.contains($0.id) } }
            selectedZooms = []
        } else if let clip = selectedClip, let project, let cuts = Cuts.remove(project, index: clip) {
            update("Delete Clip") { $0.cuts = cuts }
            selectedClip = nil
        }
    }

    // MARK: Mockup

    func select(shot id: UUID, extend: Bool = false) {
        selectedClip = nil
        selectedZooms = []
        selectedBlurs = []
        if extend {
            if selectedShots.contains(id) { selectedShots.remove(id) } else { selectedShots.insert(id) }
        } else {
            selectedShots = [id]
        }
        inspectorTab = .mockup
    }

    func setMockup(_ device: MockupSettings.Device) {
        update(device == .none ? "Remove Mockup" : "Add Phone Mockup") {
            $0.mockup.device = device
            if device != .none, $0.cameraClips.isEmpty {
                $0.cameraClips = MockupCamera.autoShots(duration: $0.recording.duration, zooms: $0.zooms)
            }
        }
    }

    /// Rebuilds the shot list: close-ups on the zooms, varied wide shots in between.
    func autoCamera() {
        update("Auto Camera") { $0.cameraClips = MockupCamera.autoShots(duration: $0.recording.duration, zooms: $0.zooms) }
        selectedShots = []
    }

    /// Changes the selected shots to `preset`, or adds a shot at the playhead if none is selected.
    func applyShot(_ preset: CameraPreset) {
        if !selectedShots.isEmpty {
            let ids = selectedShots
            update("Change Shot") { $0.cameraClips = TimelineEdits.update($0.cameraClips, ids: ids) { $0.preset = preset } }
        } else {
            addShot(preset, at: playheadTime)
        }
    }

    func addShot(_ preset: CameraPreset = .hero, at time: Seconds) {
        guard let project, let range = TimelineEdits.freeRange(at: time, in: project.cameraClips, duration: project.recording.duration, length: 4)
        else { return }
        let shot = CameraClip(range: range, preset: preset)
        update("Add Shot") { $0.cameraClips.append(shot) }
        select(shot: shot.id)
    }

    func updateSelectedShots(_ actionName: String, coalesce: Bool = false, _ change: @escaping (inout CameraClip) -> Void) {
        let ids = selectedShots
        guard !ids.isEmpty else { return }
        update(actionName, coalesce: coalesce) { $0.cameraClips = TimelineEdits.update($0.cameraClips, ids: ids, change) }
    }

    /// Splits the video clip under the playhead.
    func splitAtPlayhead() {
        guard let project, let cuts = Cuts.split(project, at: playheadTime) else { return }
        update("Split Clip") { $0.cuts = cuts }
    }

    /// Sets the fixed focus of the selected zooms (source unit coordinates).
    func setFocus(_ point: UnitPoint2D) {
        updateSelectedZooms("Set Zoom Focus") { $0.focus = .fixed(point) }
        isPickingFocus = false
    }

    /// Re-places automatic zooms (manual ones are kept) as one undoable edit.
    func regenerateAutoZooms(_ actionName: String = "Regenerate Zooms", coalesce: Bool = false, _ change: (inout Project) -> Void = { _ in }) {
        guard let telemetry else { return }
        update(actionName, coalesce: coalesce) {
            change(&$0)
            AutoZoom.regenerate(&$0, telemetry: telemetry)
        }
    }

    private func apply(_ next: Project, actionName: String, undoTo previous: Project?) {
        let old = project
        project = next
        let cursorChanged = old?.cursor != next.cursor
        if cursorChanged { rebuildCursorTrack() }
        if cursorChanged || old?.zooms != next.zooms || old?.canvas != next.canvas || old?.recording != next.recording {
            rebuildCameraTrack()
        }
        if old?.cuts != next.cuts { syncPlaybackCuts() }
        if old?.keystrokes != next.keystrokes { rebuildKeystrokeTrack() }
        if old?.audio != next.audio { syncVolumes() }
        // Drop selections that no longer exist (undo, delete).
        selectedZooms.formIntersection(next.zooms.map(\.id))
        selectedShots.formIntersection(next.cameraClips.map(\.id))
        selectedBlurs.formIntersection(next.redactions.map(\.id))
        if let clip = selectedClip, clip >= Cuts.kept(next).count { selectedClip = nil }
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
