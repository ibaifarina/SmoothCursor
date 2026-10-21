import AppKit
import SCCore
import SCExport
import SCProject
import SwiftUI

/// One-tap output setups for common destinations.
enum ExportPreset: String, CaseIterable, Identifiable {
    case youtube4K, youtube, social, vertical, portrait, square, gif, master
    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube4K: "YouTube 4K"
        case .youtube: "YouTube"
        case .social: "X · LinkedIn"
        case .vertical: "Reels · TikTok"
        case .portrait: "Instagram"
        case .square: "Square"
        case .gif: "GIF"
        case .master: "ProRes master"
        }
    }

    var subtitle: String {
        switch self {
        case .youtube4K: "16:9 · 2160p60 · HEVC"
        case .youtube: "16:9 · 1080p60"
        case .social: "16:9 · 1080p30"
        case .vertical: "9:16 · 1080p30"
        case .portrait: "4:5 · 1080p30"
        case .square: "1:1 · 1080p30"
        case .gif: "480p · 20 fps"
        case .master: "2160p · ProRes 422"
        }
    }

    var icon: String {
        switch self {
        case .youtube4K, .youtube, .social: "rectangle"
        case .vertical: "rectangle.portrait"
        case .portrait: "rectangle.portrait"
        case .square: "square"
        case .gif: "photo.stack"
        case .master: "film.stack"
        }
    }

    /// Applies the preset. Changes the canvas aspect too, except for GIF and the master.
    func apply(to p: inout Project) {
        var e = p.export
        e.format = .mp4
        e.codec = .h264
        e.quality = 0.8
        switch self {
        case .youtube4K: p.canvas.aspect = .wide16x9; e.height = 2160; e.fps = 60; e.codec = .hevc
        case .youtube: p.canvas.aspect = .wide16x9; e.height = 1080; e.fps = 60
        case .social: p.canvas.aspect = .wide16x9; e.height = 1080; e.fps = 30
        case .vertical: p.canvas.aspect = .vertical9x16; e.height = 1080; e.fps = 30
        case .portrait: p.canvas.aspect = .portrait4x5; e.height = 1080; e.fps = 30
        case .square: p.canvas.aspect = .square; e.height = 1080; e.fps = 30
        case .gif: e.format = .gif; e.height = 480; e.fps = 20
        case .master: e.format = .mov; e.codec = .proRes422; e.height = 2160; e.fps = 60
        }
        p.export = e
    }
}

/// The format menu combines container and codec.
private enum OutputFormat: String, CaseIterable {
    case h264, hevc, prores, gif

    var title: String {
        switch self {
        case .h264: "MP4 · H.264"
        case .hevc: "MP4 · HEVC"
        case .prores: "MOV · ProRes 422"
        case .gif: "GIF"
        }
    }

    init(_ e: ExportSettings) {
        self = e.format == .gif ? .gif : e.codec == .hevc ? .hevc : (e.codec == .proRes422 || e.codec == .proRes4444) ? .prores : .h264
    }

    func apply(to e: inout ExportSettings) {
        switch self {
        case .h264: e.format = .mp4; e.codec = .h264
        case .hevc: e.format = .mp4; e.codec = .hevc
        case .prores: e.format = .mov; e.codec = .proRes422
        case .gif: e.format = .gif; e.height = min(e.height, 720); e.fps = min(e.fps, 25)
        }
    }
}

struct ExportInspector: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: EditorModel

    private var project: Project? { model.project }
    private var settings: ExportSettings { project?.export ?? ExportSettings() }

    var body: some View {
        if let project {
            let aspect = FrameLayout.outputAspect(for: project)
            let size = settings.outputSize(aspect: aspect)
            let duration = Cuts.editedDuration(project)

            VStack(alignment: .leading, spacing: 10) {
                SCSectionHeader("Presets")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                    ForEach(ExportPreset.allCases) { preset in
                        PresetCard(preset: preset) { model.update("Apply \(preset.title) Preset") { preset.apply(to: &$0) } }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                SCSectionHeader("Output")
                SCRow(title: "Format") {
                    SCDropdown(selection: Binding(
                        get: { OutputFormat(settings) },
                        set: { f in model.update("Change Format") { f.apply(to: &$0.export) } }
                    ), options: OutputFormat.allCases.map { SCDropdownOption($0, $0.title) }, minWidth: 150)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Resolution").font(Typo.label).foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Text(verbatim: "\(size.width) × \(size.height)").font(Typo.mono).foregroundStyle(Palette.textSecondary)
                    }
                    SCSegmented(selection: model.binding(\.export.height, "Change Resolution", coalesce: false), options:
                        (settings.format == .gif ? [360, 480, 720] : [720, 1080, 1440, 2160]).map { SCSegmentOption($0, $0 == 2160 ? "4K" : "\($0)p") },
                        fill: true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Frame rate").font(Typo.label).foregroundStyle(Palette.textSecondary)
                    SCSegmented(selection: model.binding(\.export.fps, "Change Frame Rate", coalesce: false), options:
                        (settings.format == .gif ? [10, 20, 25] : [24, 30, 60]).map { SCSegmentOption($0, "\($0) fps") },
                        fill: true)
                }
                if settings.format != .gif && !(settings.codec == .proRes422 || settings.codec == .proRes4444) {
                    SCSlider(title: "Quality", value: model.binding(\.export.quality, "Change Quality"), in: 0.2...1, defaultValue: 0.8,
                             format: { $0 < 0.45 ? "Small" : $0 < 0.75 ? "Balanced" : $0 < 0.95 ? "High" : "Max" })
                }
                if settings.format != .gif {
                    Toggle("Include audio", isOn: model.binding(\.export.includeAudio, "Toggle Audio", coalesce: false))
                        .toggleStyle(.scSwitch)
                }
                HStack {
                    Label(duration.clock, systemImage: "clock").labelStyle(SCLabelStyle())
                    Spacer()
                    Text("≈ " + ByteCountFormatter.string(fromByteCount: Int64(settings.estimatedBytes(aspect: aspect, duration: duration)), countStyle: .file))
                }
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)

                Button(settings.format == .gif ? "Export GIF" : "Export Video", systemImage: "square.and.arrow.up") { export(project) }
                    .buttonStyle(.sc(.primary, size: .large))
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut("e", modifiers: .command)
            }

            ExportJobsList(projectID: project.id)
        }
    }

    private func export(_ project: Project) {
        let panel = NSSavePanel()
        let ext = project.export.format == .gif ? "gif" : project.export.format == .mov || project.export.codec == .proRes422 ? "mov" : "mp4"
        panel.allowedContentTypes = [.init(filenameExtension: ext)!]
        panel.nameFieldStringValue = "\(project.name).\(ext)"
        panel.directoryURL = URL.desktopDirectory
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.flush()
            app.exports.enqueue(
                ExportRequest(project: project, packageURL: model.packageURL, destination: url,
                              cursor: model.cursorTrack, camera: model.cameraTrack),
                name: url.lastPathComponent
            )
        }
    }
}

private struct PresetCard: View {
    let preset: ExportPreset
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: preset.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.title).font(Typo.label).foregroundStyle(Palette.text).lineLimit(1)
                    Text(preset.subtitle).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(hovering ? Palette.hover : Palette.raised, in: .rect(cornerRadius: Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.stroke))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

struct ExportJobsList: View {
    @Environment(AppModel.self) private var app
    let projectID: UUID?

    private var jobs: [ExportQueue.Job] {
        app.exports.jobs.filter { projectID == nil || $0.projectID == projectID }.reversed()
    }

    var body: some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SCSectionHeader("Exports") {
                    if jobs.contains(where: { $0.state.isFinished }) {
                        Button("Clear") { app.exports.clearFinished() }.buttonStyle(.sc(.ghost, size: .small))
                    }
                }
                ForEach(jobs) { ExportJobRow(job: $0) }
            }
        }
    }
}

private struct ExportJobRow: View {
    @Environment(AppModel.self) private var app
    let job: ExportQueue.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                icon
                Text(job.name).font(Typo.label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                actions
            }
            if case let .running(p) = job.state {
                ProgressBar(value: p)
                HStack {
                    Text("\(Int(p * 100))%")
                    Spacer()
                    if let r = job.remaining { Text("\(Int(r.rounded(.up))) s left") }
                }
                .font(Typo.caption).foregroundStyle(Palette.textTertiary)
            } else if case let .failed(message) = job.state {
                Text(message).font(Typo.caption).foregroundStyle(Palette.record).fixedSize(horizontal: false, vertical: true)
            } else if job.state == .queued {
                Text("Waiting…").font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(10)
        .background(Palette.raised, in: .rect(cornerRadius: Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.stroke))
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.record)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(Palette.textTertiary)
        default: ProgressView().controlSize(.mini)
        }
    }

    @ViewBuilder private var actions: some View {
        if job.state == .done {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([job.destination as NSURL])
            }
            .buttonStyle(.scIcon(size: 22))
            .help("Copy the file (paste it into Slack, Mail, X…)")
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) }
                .buttonStyle(.scIcon(size: 22))
                .help("Show in Finder")
        } else if !job.state.isFinished {
            Button("Cancel", systemImage: "xmark") { app.exports.cancel(job.id) }
                .buttonStyle(.scIcon(size: 22))
                .help("Cancel export")
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hover)
                Capsule().fill(Palette.accent).frame(width: max(geo.size.width * value, 4))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}
