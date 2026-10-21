import SCCore
import SCProject
import SCRender
import SwiftUI

/// The canvas area: the Metal preview framed at the output aspect, plus the crop editor.
struct CanvasStage: View {
    @Bindable var model: EditorModel
    let project: Project

    private var aspect: Double {
        model.isCropping ? project.recording.pixelSize.aspect : FrameLayout.outputAspect(for: project)
    }

    var body: some View {
        GeometryReader { geo in
            let size = FrameLayout.fit(aspect: aspect, in: CGRect(origin: .zero, size: geo.size)).size
            ZStack {
                MetalPreview(
                    project: project, playback: model.playback, cursorTrack: model.cursorTrack, cameraTrack: model.isPickingFocus ? nil : model.cameraTrack,
                    cropEditing: model.isCropping, packageURL: model.packageURL
                )
                if model.isPickingFocus && !model.isCropping {
                    FocusPicker(project: project) { model.setFocus($0) }
                }
                if model.isCropping {
                    CropOverlay(
                        crop: model.binding(\.canvas.crop, "Crop"),
                        sourceAspect: project.recording.pixelSize.aspect,
                        lock: $model.cropLock
                    )
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.stroke))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(duration: 0.35), value: aspect)
        }
        // Leave room above the canvas for the crop toolbar so it never covers a handle.
        .padding(.top, model.isCropping ? 46 : 0)
        .overlay(alignment: .top) {
            if model.isCropping {
                CropToolbar(model: model, project: project)
                    .padding(.top, -12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

struct MetalPreview: NSViewRepresentable {
    let project: Project
    let playback: PlaybackController?
    let cursorTrack: CursorTrack?
    let cameraTrack: CameraTrack?
    let cropEditing: Bool
    let packageURL: URL

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        let package = packageURL
        view.imageResolver = { source in
            if case let .projectFile(path) = source { return package.appending(path: path) }
            return nil
        }
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.playback = playback
        view.cursorTrack = cursorTrack
        view.cameraTrack = cameraTrack
        view.cropEditing = cropEditing
        view.project = project
    }
}

// MARK: - Focus picking

/// Click anywhere on the (unzoomed) recording to set the selected zooms' fixed focus.
private struct FocusPicker: View {
    let project: Project
    let pick: (UnitPoint2D) -> Void
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let layout = FrameLayout.base(project: project, outputSize: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                if let hover {
                    let zoomed = CGSize(width: geo.size.width / 2, height: geo.size.height / 2)
                    RoundedRectangle(cornerRadius: Radius.s)
                        .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .frame(width: zoomed.width, height: zoomed.height)
                        .position(hover)
                    Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.accent).position(hover)
                }
                Text("Click where the zoom should focus · Esc to cancel")
                    .font(Typo.label)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Palette.surface, in: .capsule)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                if case let .active(p) = phase { hover = p } else { hover = nil }
            }
            .onTapGesture { p in
                let s = layout.screenRect, crop = layout.sourceCrop
                guard s.width > 0, s.height > 0 else { return }
                let u = CGPoint(x: min(max((p.x - s.minX) / s.width, 0), 1), y: min(max((p.y - s.minY) / s.height, 0), 1))
                pick(UnitPoint2D(x: crop.x + u.x * crop.width, y: crop.y + u.y * crop.height))
            }
            .pointerStyle(.rectSelection)
        }
    }
}

// MARK: - Crop

enum CropLock: Hashable, CaseIterable {
    case free, wide, vertical, square, classic, portrait

    var title: String {
        switch self {
        case .free: "Free"
        case .wide: "16:9"
        case .vertical: "9:16"
        case .square: "1:1"
        case .classic: "4:3"
        case .portrait: "4:5"
        }
    }

    /// Width ÷ height in pixels.
    var ratio: Double? {
        switch self {
        case .free: nil
        case .wide: 16.0 / 9
        case .vertical: 9.0 / 16
        case .square: 1
        case .classic: 4.0 / 3
        case .portrait: 4.0 / 5
        }
    }
}

private struct CropToolbar: View {
    @Bindable var model: EditorModel
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "crop").foregroundStyle(Palette.accent)
            SCSegmented(selection: $model.cropLock, options: CropLock.allCases.map { SCSegmentOption($0, $0.title) })
            SCDivider(vertical: true).frame(height: 18)
            Button("Reset") {
                model.cropLock = .free
                model.update("Reset Crop") { $0.canvas.crop = .full }
            }
            .buttonStyle(.sc(.ghost, size: .small))
            .disabled(project.canvas.crop == .full)
            Button("Done") { withAnimation(.spring(duration: 0.3)) { model.isCropping = false } }
                .buttonStyle(.sc(.primary, size: .small))
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.strokeStrong))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .onChange(of: model.cropLock) { _, lock in
            guard let ratio = lock.ratio else { return }
            let aspect = project.recording.pixelSize.aspect
            model.update("Crop") { $0.canvas.crop = CropGeometry.conform($0.canvas.crop, unitRatio: ratio / aspect) }
        }
    }
}

/// Dims everything outside the crop and offers 8 resize handles plus drag-to-move.
private struct CropOverlay: View {
    @Binding var crop: UnitRect
    let sourceAspect: Double
    @Binding var lock: CropLock

    @State private var dragStart: UnitRect?
    @State private var activeHandle: CropGeometry.Handle?

    var body: some View {
        GeometryReader { geo in
            let source = FrameLayout.cropEditingSourceRect(canvasSize: geo.size, sourceAspect: sourceAspect)
            let rect = CGRect(
                x: source.minX + crop.x * source.width, y: source.minY + crop.y * source.height,
                width: crop.width * source.width, height: crop.height * source.height
            )
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(rect)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // Interior: move.
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: rect.width, height: rect.height)
                    .overlay { if activeHandle != nil { ThirdsGrid() } }
                    .overlay(Rectangle().strokeBorder(.white, lineWidth: 1.5))
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(drag(.move, source: source))
                    .pointerStyle(activeHandle == .move ? .grabActive : .grabIdle)

                ForEach(CropGeometry.Handle.resizers, id: \.self) { handle in
                    let p = handle.anchor(in: rect)
                    HandleKnob(isEdge: handle.isEdge, vertical: handle == .left || handle == .right)
                        .position(p)
                        .gesture(drag(handle, source: source))
                        .pointerStyle(.frameResize(position: handle.resizePosition))
                }
            }
        }
    }

    private func drag(_ handle: CropGeometry.Handle, source: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = crop; activeHandle = handle }
                guard let start = dragStart, source.width > 0, source.height > 0 else { return }
                let delta = CGSize(width: value.translation.width / source.width, height: value.translation.height / source.height)
                crop = CropGeometry.apply(handle, to: start, delta: delta, unitRatio: lock.ratio.map { $0 / sourceAspect })
            }
            .onEnded { _ in
                dragStart = nil
                activeHandle = nil
            }
    }
}

private struct HandleKnob: View {
    let isEdge: Bool
    let vertical: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: isEdge ? (vertical ? 6 : 22) : 13, height: isEdge ? (vertical ? 22 : 6) : 13)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .frame(width: 28, height: 28)
            .contentShape(.rect)
    }
}

private struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    let x = geo.size.width * Double(i) / 3, y = geo.size.height * Double(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

extension CropGeometry.Handle {
    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left, .move: .leading
        }
    }
}
