import SCCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            SCDivider(vertical: true)
            VStack(spacing: 4) {
                ForEach(InspectorTab.allCases) { tab in
                    Button(tab.title, systemImage: tab.symbol) {
                        withAnimation(.easeOut(duration: 0.15)) { model.inspectorTab = tab }
                    }
                    .buttonStyle(.scIcon(size: 32, active: model.inspectorTab == tab))
                    .help(tab.title)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.inspectorTab {
        case .background: BackgroundInspector(model: model)
        case .cursor: CursorInspector(model: model)
        case .zoom: ZoomInspector(model: model)
        case .mockup: comingSoon("3D phone mockups", step: 9, icon: "iphone")
        case .export: comingSoon("Export", step: 8, icon: "square.and.arrow.up")
        }
    }

    private func comingSoon(_ title: String, step: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SCSectionHeader(title)
            SCPanel {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(Palette.textTertiary)
                    Text("Arrives in step \(step).").font(Typo.label).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct BackgroundInspector: View {
    @Bindable var model: EditorModel

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

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)
        VStack(alignment: .leading, spacing: 12) {
            SCSectionHeader("Gradients")
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(Self.gradients, id: \.self) { swatch(.gradient($0)) }
            }
            SCSectionHeader("Colors").padding(.top, 6)
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(Self.swatches, id: \.self) { swatch(.color($0)) }
            }
        }
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Frame")
            SCSlider(title: "Padding", value: model.binding(\.canvas.padding, "Change Padding"), in: 0...0.3, defaultValue: 0.08,
                     format: { "\(Int($0 * 100))%" })
            SCSlider(title: "Corner radius", value: model.binding(\.canvas.cornerRadius, "Change Corner Radius"), in: 0...60,
                     defaultValue: 14, format: { "\(Int($0)) px" })
            Toggle("Shadow", isOn: model.binding(\.canvas.shadow.enabled, "Toggle Shadow", coalesce: false))
                .toggleStyle(.scSwitch)
            SCSlider(title: "Shadow strength", value: model.binding(\.canvas.shadow.opacity, "Change Shadow"), in: 0...1,
                     defaultValue: 0.45, format: { "\(Int($0 * 100))%" })
                .disabled(!(model.project?.canvas.shadow.enabled ?? false))
        }
    }

    private func swatch(_ background: Background) -> some View {
        Swatch(background: background, selected: model.project?.canvas.background == background) {
            model.update("Change Background") { $0.canvas.background = background }
        }
    }
}

private struct Swatch: View {
    let background: Background
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            background.swiftUIView
                .frame(height: 34)
                .clipShape(.rect(cornerRadius: Radius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.s)
                        .strokeBorder(selected ? Palette.accent : hovering ? Palette.strokeStrong : Palette.stroke, lineWidth: selected ? 2 : 1)
                }
                .padding(selected ? 0 : 0)
                .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

private struct CursorInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Cursor")
            Toggle("Show cursor", isOn: model.binding(\.cursor.visible, "Toggle Cursor", coalesce: false))
                .toggleStyle(.scSwitch)
            SCSlider(title: "Size", value: model.binding(\.cursor.scale, "Change Cursor Size"), in: 0.5...4, defaultValue: 1.5,
                     format: { String(format: "%.1f×", $0) })
            SCSlider(title: "Smoothing", value: model.binding(\.cursor.smoothingAmount, "Change Smoothing"), in: 0...1,
                     defaultValue: 0.7, format: { "\(Int($0 * 100))%" })
            Toggle("Hide when idle", isOn: model.binding(\.cursor.hideWhenIdle, "Toggle Idle Hide", coalesce: false))
                .toggleStyle(.scSwitch)
        }
        VStack(alignment: .leading, spacing: 12) {
            SCSectionHeader("Click effect")
            SCSegmented(
                selection: model.binding(\.cursor.clickEffect, "Change Click Effect", coalesce: false),
                options: CursorSettings.ClickEffect.allCases.map { SCSegmentOption($0, $0.rawValue.capitalized) },
                fill: true
            )
            Text("Cursor rendering arrives in step 4.").font(Typo.caption).foregroundStyle(Palette.textTertiary)
        }
    }
}

private struct ZoomInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Auto zoom") {
                SCBadge(text: "\(model.project?.zooms.count ?? 0) zooms")
            }
            Toggle("Place zooms automatically", isOn: model.binding(\.autoZoom.enabled, "Toggle Auto Zoom", coalesce: false))
                .toggleStyle(.scSwitch)
            SCSlider(title: "Default zoom", value: model.binding(\.autoZoom.defaultScale, "Change Zoom Scale"), in: 1.1...4,
                     defaultValue: 2, format: { String(format: "%.1f×", $0) })
            SCSlider(title: "Sensitivity", value: model.binding(\.autoZoom.sensitivity, "Change Sensitivity"), in: 0...1,
                     defaultValue: 0.5, format: { "\(Int($0 * 100))%" })
        }
    }
}
