import SCCore
import SwiftUI

// MARK: - Zoom lane

struct ZoomLane: View {
    @Bindable var model: EditorModel
    let project: Project
    let metrics: TimelineMetrics

    /// Zooms as they were when the current drag began (edits apply from here, never cumulatively).
    @State private var snapshot: [ZoomSegment]?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground()
                .contentShape(.rect)
                .onTapGesture(count: 2, coordinateSpace: .named(TimelineMetrics.space)) { p in
                    model.addZoom(at: metrics.time(p.x))
                }
                .onTapGesture(count: 1, coordinateSpace: .named(TimelineMetrics.space)) { p in
                    model.clearSelection()
                    model.playback?.seek(to: metrics.time(p.x))
                }
                .help("Double-click to add a zoom")

            ForEach(project.zooms) { zoom in
                let width = max(CGFloat(zoom.range.duration) * metrics.pps, 8)
                ZoomBlock(zoom: zoom, selected: model.selectedZooms.contains(zoom.id), width: width)
                    .frame(width: width, height: TimelineMetrics.zoomHeight)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { model.playback?.seek(to: zoom.range.start) }
                    .onTapGesture { model.select(zoom: zoom.id, extend: extendingSelection) }
                    .gesture(moveGesture(zoom))
                    .pointerStyle(.grabIdle)
                    .overlay(alignment: .leading) { handle(zoom, .start) }
                    .overlay(alignment: .trailing) { handle(zoom, .end) }
                    .contextMenu { menu(zoom) }
                    .offset(x: metrics.x(zoom.range.start))
            }
        }
    }

    private func moveGesture(_ zoom: ZoomSegment) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(TimelineMetrics.space))
            .onChanged { g in
                if snapshot == nil {
                    snapshot = project.zooms
                    if !model.selectedZooms.contains(zoom.id) { model.select(zoom: zoom.id, extend: extendingSelection) }
                }
                guard let snap = snapshot, let original = snap.first(where: { $0.id == zoom.id }) else { return }
                let ids = model.selectedZooms
                var delta = Double(g.translation.width / metrics.pps)
                if !snappingDisabled {
                    let candidates = snapCandidates(project: project, playhead: model.playheadTime, excluding: ids)
                    delta = Snapping.snapDelta(range: original.range, delta: delta, candidates: candidates, threshold: metrics.snapThreshold)
                }
                let moved = ZoomEdits.move(snap, ids: ids, by: delta, duration: metrics.duration)
                model.update(ids.count == 1 ? "Move Zoom" : "Move Zooms", coalesce: true) { $0.zooms = moved }
            }
            .onEnded { _ in snapshot = nil }
    }

    private func handle(_ zoom: ZoomSegment, _ edge: ZoomEdits.Edge) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineMetrics.space))
                    .onChanged { g in
                        if snapshot == nil {
                            snapshot = project.zooms
                            model.select(zoom: zoom.id)
                        }
                        guard let snap = snapshot, let original = snap.first(where: { $0.id == zoom.id }) else { return }
                        var t = (edge == .start ? original.range.start : original.range.end) + Double(g.translation.width / metrics.pps)
                        if !snappingDisabled {
                            t = Snapping.snap(t, to: snapCandidates(project: project, playhead: model.playheadTime, excluding: [zoom.id]),
                                              threshold: metrics.snapThreshold)
                        }
                        let resized = ZoomEdits.resize(snap, id: zoom.id, edge: edge, to: t, duration: metrics.duration)
                        model.update("Resize Zoom", coalesce: true) { $0.zooms = resized }
                    }
                    .onEnded { _ in snapshot = nil }
            )
    }

    @ViewBuilder private func menu(_ zoom: ZoomSegment) -> some View {
        Button("Follow Cursor") {
            model.select(zoom: zoom.id)
            model.updateSelectedZooms("Follow Cursor") { $0.focus = .followCursor(deadZone: 0.22) }
        }
        Button("Fixed Point…") {
            model.select(zoom: zoom.id)
            model.isPickingFocus = true
        }
        Divider()
        Button("Delete Zoom", role: .destructive) {
            model.select(zoom: zoom.id)
            model.deleteSelection()
        }
    }
}

private struct ZoomBlock: View {
    let zoom: ZoomSegment
    let selected: Bool
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        let tint = Palette.trackZoom
        HStack(spacing: 5) {
            if width > 44 {
                Image(systemName: zoom.focus.isFollow ? "scope" : "plus.magnifyingglass").font(.system(size: 9, weight: .bold))
                Text(String(format: "%.1f×", zoom.scale)).lineLimit(1)
            }
            if width > 110, zoom.origin == .auto {
                Image(systemName: "wand.and.stars").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.95))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(selected ? 0.85 : hovering ? 0.65 : 0.5), in: .rect(cornerRadius: Radius.s))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.s)
                .strokeBorder(selected ? Color.white : tint.opacity(0.95), lineWidth: selected ? 1.5 : 1)
        }
        // Ramps showing the zoom-in and zoom-out transitions.
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Path { p in
                    let total = max(zoom.range.duration, 0.01)
                    let inW = geo.size.width * zoom.transitionIn / total, outW = geo.size.width * zoom.transitionOut / total
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    p.addLine(to: CGPoint(x: min(inW, geo.size.width / 2), y: geo.size.height - 4))
                    p.addLine(to: CGPoint(x: max(geo.size.width - outW, geo.size.width / 2), y: geo.size.height - 4))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                }
                .stroke(.white.opacity(0.45), lineWidth: 1)
            }
            .frame(height: 6)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Video lane

struct VideoLane: View {
    @Bindable var model: EditorModel
    let project: Project
    let metrics: TimelineMetrics
    @State private var snapshot: Project?

    var body: some View {
        let clips = Cuts.kept(project)
        ZStack(alignment: .topLeading) {
            RemovedRegion()
                .frame(width: metrics.x(metrics.duration) - metrics.x(0))
                .offset(x: metrics.x(0))
                .onTapGesture(coordinateSpace: .named(TimelineMetrics.space)) { p in
                    model.clearSelection()
                    model.playback?.seek(to: metrics.time(p.x))
                }
            ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                let width = max(CGFloat(clip.duration) * metrics.pps, 6)
                ClipBlock(title: clips.count > 1 ? "Clip \(index + 1) · \(clip.duration.clock)" : "\(project.name) · \(clip.duration.clock)",
                          selected: model.selectedClip == index, width: width)
                    .frame(width: width, height: TimelineMetrics.videoHeight)
                    .contentShape(.rect)
                    .onTapGesture {
                        model.selectedZooms = []
                        model.selectedClip = index
                    }
                    .overlay(alignment: .leading) { trimHandle(index, .start) }
                    .overlay(alignment: .trailing) { trimHandle(index, .end) }
                    .contextMenu {
                        Button("Split at Playhead") { model.splitAtPlayhead() }
                        Button("Delete Clip", role: .destructive) {
                            model.selectedClip = index
                            model.deleteSelection()
                        }
                        .disabled(clips.count < 2)
                    }
                    .offset(x: metrics.x(clip.start))
            }
        }
    }

    private func trimHandle(_ index: Int, _ edge: ZoomEdits.Edge) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(0.85))
            .frame(width: 3, height: 14)
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineMetrics.space))
                    .onChanged { g in
                        if snapshot == nil { snapshot = project; model.selectedClip = index }
                        guard let snap = snapshot else { return }
                        let original = Cuts.kept(snap)[index]
                        var t = (edge == .start ? original.start : original.end) + Double(g.translation.width / metrics.pps)
                        if !snappingDisabled {
                            t = Snapping.snap(t, to: [model.playheadTime] + snap.zooms.flatMap { [$0.range.start, $0.range.end] },
                                              threshold: metrics.snapThreshold)
                        }
                        let cuts = Cuts.trim(snap, index: index, edge: edge, to: t)
                        model.update("Trim Clip", coalesce: true) { $0.cuts = cuts }
                        model.playback?.seek(to: t)
                    }
                    .onEnded { _ in snapshot = nil }
            )
    }
}

private struct ClipBlock: View {
    let title: String
    let selected: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            if width > 70 {
                Image(systemName: "film").font(.system(size: 9, weight: .bold))
                Text(title).lineLimit(1)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.trackVideo.opacity(selected ? 0.8 : 0.55), in: .rect(cornerRadius: Radius.s))
        .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(selected ? .white : Palette.trackVideo, lineWidth: selected ? 1.5 : 1))
    }
}

// MARK: - Audio & camera lanes

struct AudioLane: View {
    let peaks: [Float]
    let kept: [TimeRange]
    let metrics: TimelineMetrics
    private let chunk: CGFloat = 1024
    private let peakRate = 100.0

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground()
                .frame(width: metrics.x(metrics.duration) - metrics.x(0))
                .offset(x: metrics.x(0))
            if peaks.isEmpty {
                Text("No audio").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    .frame(height: TimelineMetrics.audioHeight)
                    .offset(x: metrics.x(0) + 10)
            } else {
                LazyHStack(spacing: 0) {
                    ForEach(0..<Int((metrics.contentWidth / chunk).rounded(.up)), id: \.self) { i in
                        Canvas { ctx, size in
                            let x0 = CGFloat(i) * chunk
                            let mid = size.height / 2
                            var x: CGFloat = 0
                            while x < size.width {
                                let t = metrics.time(x0 + x)
                                let inKept = kept.contains { $0.contains(t) }
                                let index = Int(t * peakRate)
                                if index < peaks.count, x0 + x >= metrics.x(0), x0 + x <= metrics.x(metrics.duration) {
                                    // Max over the samples this column covers.
                                    let span = max(Int(peakRate / Double(metrics.pps) * 2), 1)
                                    let v = peaks[index..<min(index + span, peaks.count)].max() ?? 0
                                    let h = max(CGFloat(v) * (size.height - 6), 1)
                                    ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: 1.5, height: h), cornerRadius: 0.75),
                                             with: .color(Palette.success.opacity(inKept ? 0.75 : 0.18)))
                                }
                                x += 2.5
                            }
                        }
                        .frame(width: chunk, height: TimelineMetrics.audioHeight)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

struct CameraLane: View {
    @Bindable var model: EditorModel
    let project: Project
    let metrics: TimelineMetrics
    @State private var snapshot: [CameraClip]?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground()
                .frame(width: metrics.x(metrics.duration) - metrics.x(0))
                .offset(x: metrics.x(0))
                .contentShape(.rect)
                .onTapGesture(count: 2, coordinateSpace: .named(TimelineMetrics.space)) { p in
                    if !project.mockup.isEnabled { model.setMockup(.phone) }
                    model.addShot(at: metrics.time(p.x))
                }
                .onTapGesture(count: 1, coordinateSpace: .named(TimelineMetrics.space)) { p in
                    model.clearSelection()
                    model.playback?.seek(to: metrics.time(p.x))
                }
                .help(project.mockup.isEnabled ? "Double-click to add a camera shot" : "Camera shots move the 3D phone. Double-click to add one.")
            ForEach(project.cameraClips) { clip in
                let width = max(CGFloat(clip.range.duration) * metrics.pps, 8)
                ShotBlock(clip: clip, selected: model.selectedShots.contains(clip.id), width: width, active: project.mockup.isEnabled)
                    .frame(width: width, height: TimelineMetrics.cameraHeight)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { model.playback?.seek(to: clip.range.start) }
                    .onTapGesture { model.select(shot: clip.id, extend: extendingSelection) }
                    .gesture(moveGesture(clip))
                    .pointerStyle(.grabIdle)
                    .overlay(alignment: .leading) { handle(clip, .start) }
                    .overlay(alignment: .trailing) { handle(clip, .end) }
                    .contextMenu {
                        ForEach(CameraPreset.allCases, id: \.self) { preset in
                            Button(preset.label) {
                                model.select(shot: clip.id)
                                model.applyShot(preset)
                            }
                        }
                        Divider()
                        Button("Delete Shot", role: .destructive) {
                            model.select(shot: clip.id)
                            model.deleteSelection()
                        }
                    }
                    .offset(x: metrics.x(clip.range.start))
            }
        }
    }

    private func moveGesture(_ clip: CameraClip) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(TimelineMetrics.space))
            .onChanged { g in
                if snapshot == nil {
                    snapshot = project.cameraClips
                    if !model.selectedShots.contains(clip.id) { model.select(shot: clip.id, extend: extendingSelection) }
                }
                guard let snap = snapshot, let original = snap.first(where: { $0.id == clip.id }) else { return }
                let ids = model.selectedShots
                var delta = Double(g.translation.width / metrics.pps)
                if !snappingDisabled {
                    var candidates = snapCandidates(project: project, playhead: model.playheadTime)
                    for c in snap where !ids.contains(c.id) { candidates += [c.range.start, c.range.end] }
                    delta = Snapping.snapDelta(range: original.range, delta: delta, candidates: candidates, threshold: metrics.snapThreshold)
                }
                let moved = TimelineEdits.move(snap, ids: ids, by: delta, duration: metrics.duration)
                model.update("Move Shot", coalesce: true) { $0.cameraClips = moved }
            }
            .onEnded { _ in snapshot = nil }
    }

    private func handle(_ clip: CameraClip, _ edge: TimelineEdits.Edge) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineMetrics.space))
                    .onChanged { g in
                        if snapshot == nil {
                            snapshot = project.cameraClips
                            model.select(shot: clip.id)
                        }
                        guard let snap = snapshot, let original = snap.first(where: { $0.id == clip.id }) else { return }
                        var t = (edge == .start ? original.range.start : original.range.end) + Double(g.translation.width / metrics.pps)
                        if !snappingDisabled {
                            var candidates = snapCandidates(project: project, playhead: model.playheadTime)
                            for c in snap where c.id != clip.id { candidates += [c.range.start, c.range.end] }
                            t = Snapping.snap(t, to: candidates, threshold: metrics.snapThreshold)
                        }
                        let resized = TimelineEdits.resize(snap, id: clip.id, edge: edge, to: t, duration: metrics.duration)
                        model.update("Resize Shot", coalesce: true) { $0.cameraClips = resized }
                    }
                    .onEnded { _ in snapshot = nil }
            )
    }
}

private struct ShotBlock: View {
    let clip: CameraClip
    let selected: Bool
    let width: CGFloat
    let active: Bool

    var body: some View {
        let tint = Palette.trackCamera
        HStack(spacing: 5) {
            if width > 40 { Image(systemName: clip.preset.symbol).font(.system(size: 9, weight: .bold)) }
            if width > 70 { Text(clip.preset.label).lineLimit(1) }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(active ? 0.95 : 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(selected ? 0.85 : active ? 0.5 : 0.22), in: .rect(cornerRadius: Radius.s))
        .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(selected ? Color.white : tint.opacity(active ? 0.95 : 0.4), lineWidth: selected ? 1.5 : 1))
    }
}

extension CameraPreset {
    var symbol: String {
        switch self {
        case .front: "rectangle.portrait"
        case .hero: "rotate.3d"
        case .straightOn: "dot.viewfinder"
        case .orbitLeft: "arrow.counterclockwise"
        case .orbitRight: "arrow.clockwise"
        case .tiltUp: "arrow.up.and.down"
        case .closeUp: "plus.magnifyingglass"
        }
    }
}
