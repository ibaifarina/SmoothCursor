import SCCore
import SCProject
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
                CanvasPreview(project: project, poster: model.posterFrame)
                    .padding(20)
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
            TimelinePlaceholder(project: project, playhead: $model.playhead)
                .frame(height: 176)
                .background(Palette.surface)
        }
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

/// SwiftUI stand-in for the Metal canvas (step 3): background + padded, rounded, shadowed frame.
private struct CanvasPreview: View {
    let project: Project
    let poster: CGImage?

    var body: some View {
        GeometryReader { geo in
            let source = project.recording.pixelSize.aspect
            let canvasAspect = project.canvas.aspect.ratio(source: source)
            let canvas = fit(aspect: canvasAspect, in: geo.size)
            let inset = min(canvas.width, canvas.height) * project.canvas.padding
            let inner = fit(aspect: source, in: CGSize(width: canvas.width - inset * 2, height: canvas.height - inset * 2))
            let scale = canvas.height / 1080

            ZStack {
                project.canvas.background.swiftUIView
                Group {
                    if let poster {
                        Image(decorative: poster, scale: 1).resizable()
                    } else {
                        Color.black
                    }
                }
                .frame(width: inner.width, height: inner.height)
                .clipShape(.rect(cornerRadius: project.canvas.cornerRadius * scale))
                .shadow(
                    color: .black.opacity(project.canvas.shadow.enabled ? project.canvas.shadow.opacity : 0),
                    radius: project.canvas.shadow.radius * scale / 2,
                    y: project.canvas.shadow.offsetY * scale
                )
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipShape(.rect(cornerRadius: Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.stroke))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fit(aspect: Double, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }
}

private struct TransportBar: View {
    @Bindable var model: EditorModel
    let duration: Seconds

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Button("Zoom", systemImage: "plus") {
                    let start = model.playhead
                    model.update("Add Zoom") {
                        $0.zooms.append(ZoomSegment(range: TimeRange(start: start, end: min(start + 2, duration))))
                    }
                }
                .buttonStyle(.sc(.ghost, size: .small))
                .help("Add a zoom at the playhead")
                Spacer()
                SCDropdown(
                    selection: model.binding(\.canvas.aspect, "Change Aspect Ratio", coalesce: false),
                    options: AspectRatio.presets.map { SCDropdownOption($0, $0.label, icon: $0.symbol) },
                    minWidth: 150
                )
            }
            HStack(spacing: 14) {
                Text(model.playhead.timecode).font(Typo.mono).frame(width: 74, alignment: .trailing)
                HStack(spacing: 2) {
                    Button("Start", systemImage: "backward.end.fill") { model.playhead = 0 }
                        .buttonStyle(.scIcon(size: 26))
                    Button("Play", systemImage: "play.fill") {}
                        .buttonStyle(.scIcon(size: 30))
                        .disabled(true) // Step 3
                    Button("End", systemImage: "forward.end.fill") { model.playhead = duration }
                        .buttonStyle(.scIcon(size: 26))
                }
                Text(duration.timecode).font(Typo.mono).foregroundStyle(Palette.textTertiary).frame(width: 74, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
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
