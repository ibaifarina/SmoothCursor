import SCCore
import SCProject
import SwiftUI

enum BackgroundKind: String, CaseIterable { case color, gradient, image }

struct BackgroundInspector: View {
    @Bindable var model: EditorModel
    @State private var kind: BackgroundKind = .gradient
    @State private var importing = false

    private static let swatches: [RGBAColor] = [
        .white, RGBAColor(hex: 0xF2F2F2), RGBAColor(hex: 0xD1D5DB), RGBAColor(hex: 0x9CA3AF),
        RGBAColor(hex: 0x374151), .black, RGBAColor(hex: 0x60A5FA), RGBAColor(hex: 0x2563EB),
        RGBAColor(hex: 0xF472B6), RGBAColor(hex: 0xF97316), RGBAColor(hex: 0xFACC15), RGBAColor(hex: 0x22C55E),
        RGBAColor(hex: 0x14B8A6), RGBAColor(hex: 0xA855F7), RGBAColor(hex: 0xEC4899), RGBAColor(hex: 0x6366F1),
    ]

    private static let gradients: [GradientSpec] = [
        .sunset,
        GradientSpec(kind: .linear, stops: [.init(0, RGBAColor(hex: 0x4F46E5)), .init(1, RGBAColor(hex: 0x06B6D4))]),
        GradientSpec(kind: .linear, stops: [.init(0, RGBAColor(hex: 0xF9A8D4)), .init(1, RGBAColor(hex: 0xFDE68A))], angle: 45),
        GradientSpec(kind: .radial, stops: [.init(0, RGBAColor(hex: 0x1E293B)), .init(1, RGBAColor(hex: 0x020617))]),
        GradientSpec(kind: .mesh, stops: [], meshColors: [
            RGBAColor(hex: 0xA5F3FC), RGBAColor(hex: 0xC4B5FD), RGBAColor(hex: 0xFBCFE8),
            RGBAColor(hex: 0x93C5FD), RGBAColor(hex: 0xE0E7FF), RGBAColor(hex: 0xFDE68A),
            RGBAColor(hex: 0xBAE6FD), RGBAColor(hex: 0xFBCFE8), RGBAColor(hex: 0xFED7AA),
        ]),
        GradientSpec(kind: .linear, stops: [.init(0, RGBAColor(hex: 0x0F172A)), .init(1, RGBAColor(hex: 0x334155))], angle: 90),
        GradientSpec(kind: .angular, stops: [
            .init(0, RGBAColor(hex: 0xFF6A1F)), .init(0.5, RGBAColor(hex: 0xFF3D6E)), .init(1, RGBAColor(hex: 0xFF6A1F)),
        ]),
        GradientSpec(kind: .linear, stops: [.init(0, RGBAColor(hex: 0x22C55E)), .init(1, RGBAColor(hex: 0x14B8A6))], angle: 160),
    ]


    private var background: Background { model.project?.canvas.background ?? .default }

    var body: some View {
        StylesSection(model: model)

        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Background")
            SCSegmented(selection: Binding(get: { kind }, set: { switchKind($0) }), options: [
                SCSegmentOption(BackgroundKind.color, "Color", icon: "circle.fill"),
                SCSegmentOption(.gradient, "Gradient", icon: "circle.lefthalf.filled"),
                SCSegmentOption(.image, "Image", icon: "photo"),
            ], fill: true)

            switch kind {
            case .color: colorSection
            case .gradient: gradientSection
            case .image: ImageBackgroundSection(model: model)
            }

            SCSlider(title: "Grain", value: model.binding(\.canvas.backgroundNoise, "Change Grain"), in: 0...1, defaultValue: 0,
                     format: { $0 < 0.005 ? "Off" : "\(Int($0 * 100))%" })
        }
        .onAppear(perform: syncKind)
        .onChange(of: model.project?.canvas.background) { syncKind() }

        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Frame")
            SCSlider(title: "Padding", value: model.binding(\.canvas.padding, "Change Padding"), in: 0...0.3, defaultValue: 0.08,
                     format: { "\(Int($0 * 100))%" })
            SCSlider(title: "Corner radius", value: model.binding(\.canvas.cornerRadius, "Change Corner Radius"), in: 0...60,
                     defaultValue: 14, format: { "\(Int($0)) px" })
            Toggle("Shadow", isOn: model.binding(\.canvas.shadow.enabled, "Toggle Shadow", coalesce: false))
                .toggleStyle(.scSwitch)
            Group {
                SCSlider(title: "Shadow strength", value: model.binding(\.canvas.shadow.opacity, "Change Shadow"), in: 0...1,
                         defaultValue: 0.45, format: { "\(Int($0 * 100))%" })
                SCSlider(title: "Shadow softness", value: model.binding(\.canvas.shadow.radius, "Change Shadow"), in: 4...120,
                         defaultValue: 40, format: { "\(Int($0)) px" })
            }
            .disabled(!(model.project?.canvas.shadow.enabled ?? false))
        }
    }

    // MARK: Color

    private var colorSection: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(Self.swatches, id: \.self) { swatch(.color($0)) }
            }
            HStack(spacing: 10) {
                SCColorWell(color: Binding(
                    get: { if case let .color(c) = background { c } else { .white } },
                    set: { c in model.update("Change Background", coalesce: true) { $0.canvas.background = .color(c) } }
                ), size: 28)
                Text("Custom color").font(Typo.label).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: Gradient

    private var gradientSection: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(Self.gradients, id: \.self) { swatch(.gradient($0)) }
            }
            GradientEditor(spec: Binding(
                get: { if case let .gradient(g) = background { g } else { .sunset } },
                set: { g in model.update("Edit Gradient", coalesce: true) { $0.canvas.background = .gradient(g) } }
            ))
        }
    }

    private func swatch(_ value: Background) -> some View {
        Swatch(background: value, selected: background == value) {
            model.update("Change Background") { $0.canvas.background = value }
        }
    }

    // MARK: Kind switching

    private func syncKind() {
        kind = switch background {
        case .color: .color
        case .gradient: .gradient
        case .image: .image
        }
    }

    /// Switching keeps the look close: a gradient's first color becomes the solid color, and so on.
    private func switchKind(_ new: BackgroundKind) {
        kind = new
        switch (new, background) {
        case (.color, .gradient(let g)):
            let c = g.kind == .mesh ? (g.meshColors.first ?? .white) : (g.stops.first?.color ?? .white)
            model.update("Change Background") { $0.canvas.background = .color(c) }
        case (.gradient, .color(let c)):
            let spec = GradientSpec(kind: .linear, stops: [.init(0, c), .init(1, c.shifted(by: 0.18))])
            model.update("Change Background") { $0.canvas.background = .gradient(spec) }
        case (.color, .image), (.gradient, .image):
            model.update("Change Background") { $0.canvas.background = new == .color ? .color(RGBAColor(hex: 0x111114)) : .default }
        default:
            break // Image: wait until one is picked.
        }
    }
}

extension RGBAColor {
    /// Same color with its hue rotated, for quick two-tone gradients.
    func shifted(by amount: Double) -> RGBAColor {
        let ns = NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, al: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: &al)
        let out = NSColor(hue: (h + amount).truncatingRemainder(dividingBy: 1), saturation: max(s, 0.35), brightness: v, alpha: al)
            .usingColorSpace(.sRGB)!
        return RGBAColor(out.redComponent, out.greenComponent, out.blueComponent, a)
    }
}

// MARK: - Images

private struct ImageBackgroundSection: View {
    @Bindable var model: EditorModel
    @State private var thumbnails: [URL: CGImage] = [:]
    @State private var busy = false
    @State private var importing = false

    private let wallpapers = BackgroundImages.systemWallpapers()

    private var current: ImageBackground? {
        if case let .image(i) = model.project?.canvas.background { i } else { nil }
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)
        VStack(alignment: .leading, spacing: 12) {
            if let current, case let .projectFile(path) = current.source,
               let image = BackgroundImages.thumbnail(of: model.packageURL.appending(path: path), maxPixelSize: 520) {
                FilledImage(image: image)
                    .frame(height: 90).frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: Radius.m))
                    .allowsHitTesting(false)
                    .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.accent, lineWidth: 2))
            }
            HStack(spacing: 7) {
                Button("Image…", systemImage: "photo.badge.plus") { importing = true }
                    .buttonStyle(.sc(.secondary, size: .small))
                Button("Frame", systemImage: "drop") { useFrame() }
                    .buttonStyle(.sc(.secondary, size: .small))
                    .help("Use a blurred frame of the recording at the playhead")
                if busy { ProgressView().controlSize(.small) }
            }
            if current != nil {
                SCSlider(title: "Blur", value: Binding(
                    get: { current?.blur ?? 0 },
                    set: { v in
                        guard var img = current else { return }
                        img.blur = v
                        model.update("Change Blur", coalesce: true) { $0.canvas.background = .image(img) }
                    }
                ), in: 0...1, defaultValue: 0, format: { $0 < 0.005 ? "Off" : "\(Int($0 * 100))%" })
            }
            if !wallpapers.isEmpty {
                Text("macOS wallpapers").font(Typo.label).foregroundStyle(Palette.textSecondary)
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(wallpapers, id: \.self) { url in
                        Button { use(url) } label: {
                            FilledImage(image: thumbnails[url])
                            .frame(height: 44)
                            .clipShape(.rect(cornerRadius: Radius.s))
                            .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(Palette.stroke))
                        }
                        .buttonStyle(.plain)
                        .help(url.deletingPathExtension().lastPathComponent)
                        .task { await loadThumbnail(url) }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result { use(url) }
        }
    }

    private func loadThumbnail(_ url: URL) async {
        guard thumbnails[url] == nil else { return }
        let image = await Task.detached(priority: .utility) { BackgroundImages.thumbnail(of: url, maxPixelSize: 200) }.value
        thumbnails[url] = image
    }

    private func use(_ url: URL) {
        let package = model.packageURL
        busy = true
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let path = try? await Task.detached(priority: .userInitiated) { try BackgroundImages.importImage(url, into: package) }.value
            busy = false
            guard let path else { return }
            model.update("Change Background") {
                $0.canvas.background = .image(ImageBackground(source: .projectFile(relativePath: path), blur: current?.blur ?? 0))
            }
        }
    }

    private func useFrame() {
        guard let project = model.project else { return }
        let package = model.packageURL
        let video = ProjectPackage.mediaURL(project.recording.videoFile, in: package)
        let time = model.playheadTime
        busy = true
        Task {
            let path: String? = await Task.detached(priority: .userInitiated) {
                guard let frame = await Thumbnailer.frame(of: video, at: time, maxSize: 1600) else { return nil }
                return try? BackgroundImages.importImage(frame, into: package)
            }.value
            busy = false
            guard let path else { return }
            model.update("Change Background") {
                $0.canvas.background = .image(ImageBackground(source: .projectFile(relativePath: path), blur: 0.55))
            }
        }
    }
}

/// Aspect-fill image that never draws or hit-tests outside its frame. (A bare `scaledToFill()`
/// overflows its frame and steals clicks from the controls around it.)
struct FilledImage: View {
    let image: CGImage?

    var body: some View {
        Palette.canvas
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
            .contentShape(.rect)
    }
}
