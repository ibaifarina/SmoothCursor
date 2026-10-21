import ImageIO
import SCCore
import SCProject
import SwiftUI
import UniformTypeIdentifiers

enum SpringPreset: String, CaseIterable {
    case smooth, snappy, gentle, bouncy

    var params: SpringParams {
        switch self {
        case .smooth: .smooth
        case .snappy: .snappy
        case .gentle: .gentle
        case .bouncy: .bouncy
        }
    }

    init(_ params: SpringParams) {
        self = Self.allCases.first { $0.params == params } ?? .smooth
    }
}

struct CursorInspector: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: EditorModel
    @State private var importURL: URL?

    private var cursor: CursorSettings { model.project?.cursor ?? CursorSettings() }

    var body: some View {
        if model.telemetry == nil {
            SCPanel {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cursorarrow.slash").foregroundStyle(Palette.textTertiary)
                    Text("This video has no cursor data. Cursor effects work on recordings made with Smooth Cursor.")
                        .font(Typo.label).foregroundStyle(Palette.textSecondary)
                }
            }
        }

        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Cursor")
            Toggle("Show cursor", isOn: model.binding(\.cursor.visible, "Toggle Cursor", coalesce: false))
                .toggleStyle(.scSwitch)
            styleGrid
            SCSlider(title: "Size", value: model.binding(\.cursor.scale, "Change Cursor Size"), in: 0.5...4, defaultValue: 1.5,
                     format: { String(format: "%.1f×", $0) })
        }
        .disabled(model.telemetry == nil)

        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Motion")
            SCSlider(title: "Smoothing", value: model.binding(\.cursor.smoothingAmount, "Change Smoothing"), in: 0...1,
                     defaultValue: 0.7, format: { $0 < 0.005 ? "Off" : "\(Int($0 * 100))%" })
            VStack(alignment: .leading, spacing: 7) {
                Text("Spring").font(Typo.label).foregroundStyle(Palette.textSecondary)
                SCSegmented(
                    selection: Binding(
                        get: { SpringPreset(cursor.smoothing) },
                        set: { preset in model.update("Change Spring") { $0.cursor.smoothing = preset.params } }
                    ),
                    options: SpringPreset.allCases.map { SCSegmentOption($0, $0.rawValue.capitalized) },
                    fill: true
                )
            }
            .disabled(cursor.smoothingAmount < 0.005)
            Toggle("Tilt with motion", isOn: model.binding(\.cursor.tiltWithMotion, "Toggle Tilt", coalesce: false))
                .toggleStyle(.scSwitch)
        }
        .disabled(model.telemetry == nil)

        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Visibility")
            Toggle("Hide when idle", isOn: model.binding(\.cursor.hideWhenIdle, "Toggle Idle Hide", coalesce: false))
                .toggleStyle(.scSwitch)
            SCSlider(title: "Hide after", value: model.binding(\.cursor.idleDelay, "Change Idle Delay"), in: 0.5...8, defaultValue: 2.5,
                     format: { String(format: "%.1f s", $0) })
                .disabled(!cursor.hideWhenIdle)
        }
        .disabled(model.telemetry == nil)

        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Clicks")
            SCSegmented(
                selection: model.binding(\.cursor.clickEffect, "Change Click Effect", coalesce: false),
                options: CursorSettings.ClickEffect.allCases.map { SCSegmentOption($0, $0.rawValue.capitalized) },
                fill: true
            )
            Toggle("Click sound", isOn: model.binding(\.cursor.clickSound, "Toggle Click Sound", coalesce: false))
                .toggleStyle(.scSwitch)
                .help("Adds a soft click to the exported audio on every click")
            if cursor.clickEffect == .ripple || cursor.clickEffect == .pulse {
                HStack(spacing: 8) {
                    Text("Color").font(Typo.label).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    ForEach(Self.effectColors, id: \.self) { color in
                        let selected = cursor.clickEffectColor == color
                        Button {
                            model.update("Change Click Color") { $0.cursor.clickEffectColor = color }
                        } label: {
                            Circle().fill(color.color)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(selected ? Palette.accent : Palette.strokeStrong, lineWidth: selected ? 2 : 1).padding(-3))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .disabled(model.telemetry == nil)
        .sheet(item: $importURL) { url in
            CursorImportSheet(imageURL: url) { pack in
                model.update("Change Cursor Style") { $0.cursor.sprite = .customPack(id: pack.id) }
            }
            .environment(app)
        }
    }

    static let effectColors: [RGBAColor] = [
        RGBAColor(1, 1, 1, 0.75), RGBAColor(0, 0, 0, 0.55), RGBAColor(hex: 0xFF6A1F, alpha: 0.8),
        RGBAColor(hex: 0x3B82F6, alpha: 0.8), RGBAColor(hex: 0xFACC15, alpha: 0.85),
    ]

    // MARK: Styles

    private var styleGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)
        let systemImage = model.telemetry?.header.cursorSprites.first.map { model.packageURL.appending(path: $0.imageFile) }
        return LazyVGrid(columns: columns, spacing: 7) {
            StyleCard(title: "macOS", imageURL: systemImage, selected: cursor.sprite == .system) {
                select(.system)
            }
            ForEach(app.cursorPacks.packs) { pack in
                StyleCard(
                    title: pack.name,
                    imageURL: pack.entries.first.map { app.cursorPacks.directory(for: pack.id).appending(path: $0.imageFile) },
                    selected: cursor.sprite == .customPack(id: pack.id)
                ) { select(.customPack(id: pack.id)) }
                .contextMenu {
                    if !pack.isBuiltin {
                        Button("Delete Cursor", role: .destructive) {
                            if cursor.sprite == .customPack(id: pack.id) { select(.system) }
                            try? app.cursorPacks.delete(pack)
                        }
                    }
                }
            }
            StyleCard(title: "Import", imageURL: nil, symbol: "plus", selected: false) { chooseImage() }
        }
    }

    private func select(_ sprite: CursorSettings.SpriteSource) {
        model.update("Change Cursor Style") { $0.cursor.sprite = sprite }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .heic, .jpeg]
        panel.prompt = "Choose Cursor"
        panel.message = "Pick an image with a transparent background. PNG works best."
        if panel.runModal() == .OK, let url = panel.url { importURL = url }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct StyleCard: View {
    let title: String
    let imageURL: URL?
    var symbol: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.s).fill(Palette.canvas)
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                    } else if let imageURL, let image = TrimmedImage.load(imageURL) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().padding(9)
                    }
                }
                .frame(height: 46)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.s)
                        .strokeBorder(selected ? Palette.accent : hovering ? Palette.strokeStrong : Palette.stroke, lineWidth: selected ? 2 : 1)
                }
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(selected ? Palette.text : Palette.textSecondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

/// Cursor images carry transparent padding (system ones a lot); thumbnails show just the visible part.
enum TrimmedImage {
    @MainActor private static var cache: [URL: CGImage] = [:]

    @MainActor static func load(_ url: URL) -> CGImage? {
        if let cached = cache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let trimmed = trim(image) ?? image
        cache[url] = trimmed
        return trimmed
    }

    private static func trim(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = alpha.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 24 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return nil }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}

/// Set the hotspot (click on the image), which cursors it replaces, and its size.
private struct CursorImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let imageURL: URL
    let onImport: (CursorPack) -> Void

    @State private var hotspot = UnitPoint2D(x: 0.1, y: 0.1)
    @State private var kind = "arrow"
    @State private var size = 24.0
    @State private var name = "My Cursor"
    @State private var error: String?

    private var image: NSImage? { NSImage(contentsOf: imageURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Cursor").font(Typo.title)
            HStack(alignment: .top, spacing: 18) {
                hotspotPicker
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").font(Typo.label).foregroundStyle(Palette.textSecondary)
                        SCTextField(placeholder: "Name", text: $name)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Replaces").font(Typo.label).foregroundStyle(Palette.textSecondary)
                        SCSegmented(selection: $kind, options: [
                            SCSegmentOption("arrow", "Arrow"), SCSegmentOption("pointingHand", "Pointer"),
                            SCSegmentOption("iBeam", "Text"), SCSegmentOption(CursorPack.anyKind, "All"),
                        ], fill: true)
                    }
                    SCSlider(title: "Height", value: $size, in: 12...64, step: 1, defaultValue: 24, format: { "\(Int($0)) pt" })
                    Text("Click the image to set the hotspot: the exact point that clicks.")
                        .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error { Text(error).font(Typo.caption).foregroundStyle(Palette.record) }
                }
                .frame(width: 250)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.sc(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("Import") { save() }.buttonStyle(.sc(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .background(Palette.surface)
        .preferredColorScheme(.dark)
    }

    private var hotspotPicker: some View {
        ZStack {
            Checkerboard().clipShape(.rect(cornerRadius: Radius.m))
            if let image {
                GeometryReader { geo in
                    let fitted = FrameLayout.fit(aspect: image.size.width / max(image.size.height, 1), in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 16, dy: 16))
                    Image(nsImage: image).resizable().frame(width: fitted.width, height: fitted.height).position(x: fitted.midX, y: fitted.midY)
                    Crosshair()
                        .position(x: fitted.minX + hotspot.x * fitted.width, y: fitted.minY + hotspot.y * fitted.height)
                    Color.clear.contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            hotspot = UnitPoint2D(
                                x: min(max((g.location.x - fitted.minX) / fitted.width, 0), 1),
                                y: min(max((g.location.y - fitted.minY) / fitted.height, 0), 1)
                            )
                        })
                }
            }
        }
        .frame(width: 220, height: 220)
        .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.stroke))
    }

    private func save() {
        guard let rep = image?.representations.first else { error = "Couldn't read the image."; return }
        let px = CGPoint(x: hotspot.x * Double(rep.pixelsWide), y: hotspot.y * Double(rep.pixelsHigh))
        do {
            let pack = try app.cursorPacks.importImage(imageURL, name: name.isEmpty ? "Custom" : name, kind: kind, hotspot: px, pointHeight: size)
            onImport(pack)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Palette.accent, lineWidth: 2).frame(width: 16, height: 16)
            Rectangle().fill(Palette.accent).frame(width: 1, height: 26)
            Rectangle().fill(Palette.accent).frame(width: 26, height: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s = 10.0
            for row in 0..<Int(size.height / s) + 1 {
                for col in 0..<Int(size.width / s) + 1 where (row + col).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: Double(col) * s, y: Double(row) * s, width: s, height: s)), with: .color(.white.opacity(0.06)))
                }
            }
        }
        .background(Palette.canvas)
    }
}
