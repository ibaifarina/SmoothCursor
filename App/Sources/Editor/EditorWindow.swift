import SCCore
import SCProject
import SCRender
import SwiftUI

struct EditorWindow: View {
    @Environment(AppModel.self) private var app
    @State private var model: EditorModel
    @Environment(\.undoManager) private var undoManager

    init(packageURL: URL) {
        _model = State(initialValue: EditorModel(packageURL: packageURL))
    }

    var body: some View {
        Group {
            if let project = model.project {
                EditorLayout(model: model, project: project)
            } else if let error = model.loadError {
                SCEmptyState(icon: "exclamationmark.triangle", title: "Couldn't open project", message: error) {}
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .navigationTitle(model.project?.name ?? "")
        .task { await model.load() }
        .onAppear {
            model.undoManager = undoManager
            app.register(model)
        }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .onDisappear {
            app.unregister(model)
            Task {
                await model.close()
                app.library.reload()
            }
        }
    }
}

private struct EditorLayout: View {
    @Bindable var model: EditorModel
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            EditorTitleBar(model: model, project: project)
            SCDivider()
            HStack(spacing: 0) {
                CanvasStage(model: model, project: project)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.canvas)
                SCDivider(vertical: true)
                InspectorView(model: model)
                    .frame(width: 304)
                    .background(Palette.surface)
            }
            SCDivider()
            TransportBar(model: model, duration: project.recording.duration)
                .background(Palette.surface)
            SCDivider()
            Group {
                if let playback = model.playback {
                    TimelinePlaceholder(project: project, playback: playback)
                } else {
                    Color.clear
                }
            }
            .frame(height: 176)
            .background(Palette.surface)
        }
        .background { EditorShortcuts(model: model) }
    }
}

private struct EditorTitleBar: View {
    @Bindable var model: EditorModel
    let project: Project
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @State private var editingName = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        SCTitleBar {
            Button("Projects", systemImage: "square.grid.2x2") { openWindow(id: WindowID.home) }
                .buttonStyle(.sc(.ghost, size: .small))
            SCDivider(vertical: true).frame(height: 16)
            nameField
            saveStatus
        } center: {
            HStack(spacing: 2) {
                Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                    .buttonStyle(.scIcon())
                    .disabled(!(undoManager?.canUndo ?? false))
                    .help(undoManager?.undoMenuItemTitle ?? "Undo")
                Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                    .buttonStyle(.scIcon())
                    .disabled(!(undoManager?.canRedo ?? false))
                    .help(undoManager?.redoMenuItemTitle ?? "Redo")
            }
            .id(project) // re-evaluate canUndo/canRedo after every edit
        } trailing: {
            Button("Record", systemImage: "record.circle") { openWindow(id: WindowID.recorder) }
                .buttonStyle(.sc(.secondary, size: .small))
            Button("Export", systemImage: "square.and.arrow.up") { model.inspectorTab = .export }
                .buttonStyle(.sc(.primary, size: .small))
        }
    }

    @ViewBuilder private var nameField: some View {
        if editingName {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(Typo.bodyMedium)
                .frame(width: 220)
                .focused($nameFocused)
                .padding(.horizontal, 6).frame(height: 24)
                .background(Palette.raised, in: .rect(cornerRadius: Radius.s))
                .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(Palette.accent))
                .onSubmit(commit)
                .onExitCommand { editingName = false }
                .onAppear { model.isEditingText = true }
                .onDisappear { model.isEditingText = false }
                .onChange(of: nameFocused) { if !nameFocused { commit() } }
        } else {
            Text(project.name)
                .font(Typo.bodyMedium)
                .lineLimit(1)
                .padding(.horizontal, 6).frame(height: 24)
                .contentShape(.rect)
                .onTapGesture {
                    draftName = project.name
                    editingName = true
                    nameFocused = true
                }
                .help("Click to rename")
        }
    }

    private var saveStatus: some View {
        let (text, color): (String, Color) = switch model.autosaver.status {
        case .saved: ("Saved", Palette.textTertiary)
        case .pending, .saving: ("Saving…", Palette.textSecondary)
        case .failed: ("Not saved", Palette.record)
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
        }
        .font(Typo.caption)
        .foregroundStyle(color)
        .help({ if case let .failed(message) = model.autosaver.status { message } else { "Changes are saved automatically" } }())
        .animation(.easeOut(duration: 0.2), value: model.autosaver.status)
    }

    private func commit() {
        guard editingName else { return }
        editingName = false
        model.rename(to: draftName)
    }
}

private struct TransportBar: View {
    @Bindable var model: EditorModel
    let duration: Seconds

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Button("Zoom", systemImage: "plus") {
                    let start = model.playback?.time ?? 0
                    model.update("Add Zoom") {
                        $0.zooms.append(ZoomSegment(range: TimeRange(start: start, end: min(start + 2.5, duration))))
                    }
                }
                .buttonStyle(.sc(.ghost, size: .small))
                .help("Add a zoom at the playhead")
                Spacer()
                Button("Crop", systemImage: "crop") {
                    withAnimation(.spring(duration: 0.3)) { model.isCropping.toggle() }
                }
                .buttonStyle(.scIcon(active: model.isCropping))
                .help("Crop the recording")
                SCDropdown(
                    selection: model.binding(\.canvas.aspect, "Change Aspect Ratio", coalesce: false),
                    options: AspectRatio.presets.map { SCDropdownOption($0, $0.label, icon: $0.symbol) },
                    minWidth: 150
                )
            }
            if let playback = model.playback {
                PlaybackControls(playback: playback)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

private struct PlaybackControls: View {
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 14) {
            Text(playback.time.timecode).font(Typo.mono).frame(width: 74, alignment: .trailing)
            HStack(spacing: 2) {
                Button("Start", systemImage: "backward.end.fill") { playback.seek(to: 0) }
                    .buttonStyle(.scIcon(size: 26))
                    .help("Go to start")
                Button("Previous frame", systemImage: "chevron.left") { playback.step(frames: -1) }
                    .buttonStyle(.scIcon(size: 26))
                    .help("Previous frame (←)")
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.togglePlay()
                }
                .buttonStyle(.scIcon(size: 32, active: playback.isPlaying))
                .help("Play / pause (Space)")
                Button("Next frame", systemImage: "chevron.right") { playback.step(frames: 1) }
                    .buttonStyle(.scIcon(size: 26))
                    .help("Next frame (→)")
                Button("End", systemImage: "forward.end.fill") { playback.seek(to: playback.duration) }
                    .buttonStyle(.scIcon(size: 26))
                    .help("Go to end")
            }
            Text(playback.duration.timecode).font(Typo.mono).foregroundStyle(Palette.textTertiary).frame(width: 74, alignment: .leading)
        }
    }
}

/// Single-key shortcuts, disabled while a text field is being edited.
private struct EditorShortcuts: View {
    let model: EditorModel

    var body: some View {
        if let playback = model.playback, !model.isEditingText {
            Group {
                Button("Play / Pause") { playback.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("Previous Frame") { playback.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Frame") { playback.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Back 1s") { playback.seek(to: playback.time - 1) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("Forward 1s") { playback.seek(to: playback.time + 1) }.keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("Start") { playback.seek(to: 0) }.keyboardShortcut(.home, modifiers: [])
                Button("End") { playback.seek(to: playback.duration) }.keyboardShortcut(.end, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }
}

extension AspectRatio {
    var symbol: String {
        switch self {
        case .source: "aspectratio"
        case .wide16x9, .classic4x3: "rectangle"
        case .vertical9x16, .portrait4x5: "rectangle.portrait"
        case .square: "square"
        case .custom: "rectangle.dashed"
        }
    }
}
