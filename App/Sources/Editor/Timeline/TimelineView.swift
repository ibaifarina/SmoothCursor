import SCCore
import SCRender
import SwiftUI

/// Geometry shared by all lanes: time ↔ x in the scrolling content.
struct TimelineMetrics {
    static let headerWidth: CGFloat = 116
    static let inset: CGFloat = 12
    static let rulerHeight: CGFloat = 26
    static let spacing: CGFloat = 6
    static let videoHeight: CGFloat = 34
    static let zoomHeight: CGFloat = 34
    static let audioHeight: CGFloat = 38
    static let cameraHeight: CGFloat = 26
    static let space = "timeline"

    let pps: CGFloat
    let duration: Seconds

    var contentWidth: CGFloat { CGFloat(duration) * pps + Self.inset * 2 + 24 }
    func x(_ t: Seconds) -> CGFloat { Self.inset + CGFloat(t) * pps }
    func time(_ x: CGFloat) -> Seconds { min(max(Double((x - Self.inset) / pps), 0), duration) }
    /// Snap distance: 8 px expressed in seconds.
    var snapThreshold: Seconds { Double(8 / pps) }
}

struct TimelineView: View {
    @Bindable var model: EditorModel
    let project: Project
    let playback: PlaybackController

    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var pinchBase: Double?

    var body: some View {
        GeometryReader { geo in
            let visible = max(geo.size.width - TimelineMetrics.headerWidth - 1, 100)
            let duration = max(project.recording.duration, 0.1)
            let fit = max((visible - TimelineMetrics.inset * 2 - 24) / CGFloat(duration), 0.5)
            let metrics = TimelineMetrics(pps: fit * model.timelineZoom, duration: duration)

            HStack(spacing: 0) {
                TrackHeaders(model: model)
                    .frame(width: TimelineMetrics.headerWidth)
                SCDivider(vertical: true)
                ScrollView(.horizontal) {
                    TimelineContent(model: model, project: project, playback: playback, metrics: metrics)
                        .frame(width: metrics.contentWidth, alignment: .leading)
                }
                .scrollIndicators(.visible)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in offset = x }
                .onChange(of: playback.time) { _, t in
                    // Keep the playhead in view while playing.
                    guard playback.isPlaying else { return }
                    let px = metrics.x(t)
                    if px > offset + visible - 60 || px < offset {
                        scroll.scrollTo(x: max(px - 80, 0))
                    }
                }
                .onChange(of: model.timelineZoom) { old, new in
                    // Zoom around the playhead: it stays at the same place on screen.
                    let t = CGFloat(playback.time)
                    let screenX = TimelineMetrics.inset + t * fit * old - offset
                    scroll.scrollTo(x: max(TimelineMetrics.inset + t * fit * new - screenX, 0))
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let base = pinchBase ?? model.timelineZoom
                            pinchBase = base
                            model.timelineZoom = min(max(base * value.magnification, 1), 64)
                        }
                        .onEnded { _ in pinchBase = nil }
                )
            }
        }
    }
}

private struct TrackHeaders: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: TimelineMetrics.spacing) {
            HStack(spacing: 0) {
                Button("Zoom out timeline", systemImage: "minus.magnifyingglass") {
                    model.timelineZoom = max(model.timelineZoom / 1.6, 1)
                }
                .buttonStyle(.scIcon(size: 22))
                .help("Zoom out (⌘−)")
                Button("Fit timeline", systemImage: "arrow.left.and.right") { model.timelineZoom = 1 }
                    .buttonStyle(.scIcon(size: 22))
                    .help("Fit the whole recording")
                    .disabled(model.timelineZoom <= 1.001)
                Button("Zoom in timeline", systemImage: "plus.magnifyingglass") {
                    model.timelineZoom = min(model.timelineZoom * 1.6, 64)
                }
                .buttonStyle(.scIcon(size: 22))
                .help("Zoom in (⌘+)")
            }
            .frame(height: TimelineMetrics.rulerHeight)
            .padding(.leading, 8)
            header("Video", "film", TimelineMetrics.videoHeight)
            header("Zoom", "plus.magnifyingglass", TimelineMetrics.zoomHeight)
            header("Audio", "waveform", TimelineMetrics.audioHeight)
            header("Camera", "video", TimelineMetrics.cameraHeight)
        }
        .padding(.top, 6)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func header(_ title: String, _ icon: String, _ height: CGFloat) -> some View {
        Label(title, systemImage: icon)
            .labelStyle(SCLabelStyle())
            .font(Typo.label)
            .foregroundStyle(Palette.textSecondary)
            .padding(.leading, 14)
            .frame(height: height)
    }
}

private struct TimelineContent: View {
    @Bindable var model: EditorModel
    let project: Project
    let playback: PlaybackController
    let metrics: TimelineMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: TimelineMetrics.spacing) {
            RulerLane(playback: playback, metrics: metrics)
                .frame(height: TimelineMetrics.rulerHeight)
            VideoLane(model: model, project: project, metrics: metrics)
                .frame(height: TimelineMetrics.videoHeight)
            ZoomLane(model: model, project: project, metrics: metrics)
                .frame(height: TimelineMetrics.zoomHeight)
            AudioLane(peaks: model.waveform, kept: Cuts.kept(project), metrics: metrics)
                .frame(height: TimelineMetrics.audioHeight)
            CameraLane(clips: project.cameraClips, metrics: metrics)
                .frame(height: TimelineMetrics.cameraHeight)
        }
        .padding(.top, 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            PlayheadLine()
                .offset(x: metrics.x(playback.time) - 6)
                .allowsHitTesting(false)
        }
        .coordinateSpace(.named(TimelineMetrics.space))
    }
}

// MARK: - Ruler & playhead

/// Tick spacing that keeps labels ≥ 70 px apart.
func tickStep(pps: CGFloat) -> (major: Double, minor: Double) {
    let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
    let major = steps.first { CGFloat($0) * pps >= 70 } ?? 600
    let minor = major >= 1 && major <= 2 ? major / 4 : major / 5
    return (major, minor)
}

func timelineLabel(_ t: Double, step: Double) -> String {
    let m = Int(t) / 60, s = Int(t) % 60
    if step < 1 { return String(format: "%d:%02d.%d", m, s, Int((t - floor(t)) * 10 + 0.001)) }
    return String(format: "%d:%02d", m, s)
}

private struct RulerLane: View {
    let playback: PlaybackController
    let metrics: TimelineMetrics
    @State private var scrubbing = false

    private let chunk: CGFloat = 1024

    var body: some View {
        let (major, minor) = tickStep(pps: metrics.pps)
        let count = Int((metrics.contentWidth / chunk).rounded(.up))
        LazyHStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Canvas { ctx, size in
                    let x0 = CGFloat(i) * chunk
                    let t0 = max(Double((x0 - TimelineMetrics.inset) / metrics.pps), 0)
                    let t1 = min(Double((x0 + chunk - TimelineMetrics.inset) / metrics.pps), metrics.duration)
                    var t = (t0 / minor).rounded(.down) * minor
                    while t <= t1 + 1e-9 {
                        let x = metrics.x(t) - x0
                        let isMajor = abs((t / major).rounded() * major - t) < 1e-6
                        let h: CGFloat = isMajor ? 7 : 4
                        ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 1, height: h)),
                                 with: .color(isMajor ? Palette.strokeStrong : Palette.stroke))
                        if isMajor {
                            ctx.draw(
                                Text(timelineLabel(t, step: major)).font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Palette.textTertiary),
                                at: CGPoint(x: x + 3, y: 8), anchor: .leading
                            )
                        }
                        t += minor
                    }
                }
                .frame(width: chunk, height: TimelineMetrics.rulerHeight)
            }
        }
        .frame(width: metrics.contentWidth, alignment: .leading)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineMetrics.space))
                .onChanged { g in
                    if !scrubbing { scrubbing = true; playback.beginScrub() }
                    playback.seek(to: metrics.time(g.location.x))
                }
                .onEnded { _ in scrubbing = false; playback.endScrub() }
        )
        .pointerStyle(.columnResize)
        .help("Drag to scrub")
    }
}

private struct PlayheadLine: View {
    var body: some View {
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 3)
                .fill(Palette.accent)
                .frame(width: 12, height: 14)
            Rectangle().fill(Palette.accent).frame(width: 2)
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 8)
        .shadow(color: Palette.accent.opacity(0.4), radius: 4)
    }
}

// MARK: - Shared pieces

/// Diagonal stripes for removed parts of the recording.
struct RemovedRegion: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            ctx.stroke(path, with: .color(.white.opacity(0.05)), lineWidth: 1)
        }
        .background(Palette.canvas.opacity(0.85))
        .clipShape(.rect(cornerRadius: Radius.s))
    }
}

struct LaneBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.s).fill(Palette.canvas.opacity(0.55))
    }
}

/// Snap targets: playhead, recording edges, clip edges and the edges of zooms not being dragged.
func snapCandidates(project: Project, playhead: Seconds, excluding ids: Set<UUID> = []) -> [Seconds] {
    var c: [Seconds] = [0, project.recording.duration, playhead]
    for z in project.zooms where !ids.contains(z.id) { c += [z.range.start, z.range.end] }
    for r in Cuts.kept(project) { c += [r.start, r.end] }
    return c
}

var snappingDisabled: Bool { NSEvent.modifierFlags.contains(.option) }
var extendingSelection: Bool { !NSEvent.modifierFlags.isDisjoint(with: [.shift, .command]) }
