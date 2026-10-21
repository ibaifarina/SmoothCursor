import SCCore
import SwiftUI

struct ZoomInspector: View {
    @Bindable var model: EditorModel

    private var project: Project? { model.project }
    private var zooms: [ZoomSegment] { project?.zooms.sorted { $0.range.start < $1.range.start } ?? [] }
    private var hasTelemetry: Bool { model.telemetry != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Auto zoom") {
                SCBadge(text: "\(zooms.filter { $0.origin == .auto }.count) auto · \(zooms.filter { $0.origin == .manual }.count) manual")
            }
            if !hasTelemetry {
                Text("Automatic zooms need cursor data, which imported videos don't have. Add zooms by hand with + Zoom.")
                    .font(Typo.label).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Place zooms automatically", isOn: Binding(
                get: { project?.autoZoom.enabled ?? false },
                set: { on in model.regenerateAutoZooms(on ? "Turn On Auto Zoom" : "Turn Off Auto Zoom") { $0.autoZoom.enabled = on } }
            ))
            .toggleStyle(.scSwitch)
            Group {
                SCSlider(
                    title: "Zoom level",
                    value: autoBinding(\.defaultScale, "Change Zoom Level"),
                    in: 1.2...4, defaultValue: 2, format: { String(format: "%.1f×", $0) }
                )
                SCSlider(
                    title: "Sensitivity",
                    value: autoBinding(\.sensitivity, "Change Sensitivity"),
                    in: 0...1, defaultValue: 0.5,
                    format: { $0 < 0.34 ? "Calm" : $0 < 0.67 ? "Balanced" : "Eager" }
                )
                Button("Regenerate", systemImage: "wand.and.stars") { model.regenerateAutoZooms() }
                    .buttonStyle(.sc(.secondary, size: .small))
                    .help("Re-place automatic zooms. Zooms you added or edited by hand are kept.")
            }
            .disabled(!(project?.autoZoom.enabled ?? false))
        }
        .disabled(!hasTelemetry)

        VStack(alignment: .leading, spacing: 8) {
            SCSectionHeader("Zooms")
            if zooms.isEmpty {
                Text("No zooms yet. Use + Zoom below the canvas to add one at the playhead.")
                    .font(Typo.label).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(zooms) { zoom in
                ZoomRow(zoom: zoom, isActive: zoom.range.contains(model.playback?.time ?? -1)) {
                    model.playback?.seek(to: zoom.range.start)
                } onDelete: {
                    model.update("Delete Zoom") { $0.zooms.removeAll { $0.id == zoom.id } }
                }
            }
        }
    }

    /// Changing an auto-zoom setting re-places the automatic zooms immediately.
    private func autoBinding(_ keyPath: WritableKeyPath<AutoZoomSettings, Double>, _ name: String) -> Binding<Double> {
        Binding(
            get: { project?.autoZoom[keyPath: keyPath] ?? 0 },
            set: { value in model.regenerateAutoZooms(name, coalesce: true) { $0.autoZoom[keyPath: keyPath] = value } }
        )
    }
}

private struct ZoomRow: View {
    let zoom: ZoomSegment
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: zoom.focus.isFollow ? "scope" : "plus.magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.trackZoom)
                .frame(width: 24, height: 24)
                .background(Palette.trackZoom.opacity(0.15), in: .rect(cornerRadius: Radius.s))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(zoom.range.start.clock) – \(zoom.range.end.clock)").font(Typo.mono)
                Text(String(format: "%.1f× · %@", zoom.scale, zoom.focus.isFollow ? "follow" : "fixed"))
                    .font(Typo.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
            Spacer()
            if zoom.origin == .auto { SCBadge(text: "Auto", color: Palette.trackZoom) }
            Button("Delete", systemImage: "xmark") { onDelete() }
                .buttonStyle(.scIcon(size: 22))
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? Palette.accentSoft : hovering ? Palette.hover : Palette.raised, in: .rect(cornerRadius: Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(isActive ? Palette.accent.opacity(0.5) : Palette.stroke))
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .hoverState($hovering)
    }
}

extension ZoomSegment.Focus {
    var isFollow: Bool { if case .followCursor = self { true } else { false } }
}
