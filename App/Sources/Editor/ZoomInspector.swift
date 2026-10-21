import SCCore
import SwiftUI

struct ZoomInspector: View {
    @Bindable var model: EditorModel

    private var project: Project? { model.project }
    private var zooms: [ZoomSegment] { project?.zooms.sorted { $0.range.start < $1.range.start } ?? [] }
    private var hasTelemetry: Bool { model.telemetry != nil }

    var body: some View {
        if project?.mockup.isEnabled == true {
            SCPanel(padding: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone").foregroundStyle(Palette.trackCamera)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The 3D phone is on: camera shots frame the action instead of flat zooms. Auto camera turns these zooms into close-ups.")
                            .font(Typo.label).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Button("Auto camera", systemImage: "wand.and.stars") { model.autoCamera() }
                            .buttonStyle(.sc(.secondary, size: .small))
                    }
                }
            }
        }
        if let first = zooms.first(where: { model.selectedZooms.contains($0.id) }) {
            SelectedZoomPanel(model: model, zoom: first, count: model.selectedZooms.count)
        }
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

        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Motion blur")
            Toggle("Motion blur", isOn: model.binding(\.motionBlur.enabled, "Toggle Motion Blur", coalesce: false))
                .toggleStyle(.scSwitch)
            Group {
                SCSlider(title: "Shutter", value: model.binding(\.motionBlur.amount, "Change Motion Blur"), in: 0.05...1,
                         defaultValue: 0.5, format: { "\(Int($0 * 360))°" })
                Toggle("Blur camera moves", isOn: model.binding(\.motionBlur.applyToCamera, "Toggle Camera Blur", coalesce: false))
                    .toggleStyle(.scSwitch)
                Toggle("Blur cursor", isOn: model.binding(\.motionBlur.applyToCursor, "Toggle Cursor Blur", coalesce: false))
                    .toggleStyle(.scSwitch)
            }
            .disabled(!(project?.motionBlur.enabled ?? false))
        }

        VStack(alignment: .leading, spacing: 8) {
            SCSectionHeader("Zooms")
            if zooms.isEmpty {
                Text("No zooms yet. Use + Zoom below the canvas to add one at the playhead.")
                    .font(Typo.label).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(zooms) { zoom in
                ZoomRow(zoom: zoom, isActive: model.selectedZooms.contains(zoom.id)) {
                    model.select(zoom: zoom.id, extend: extendingSelection)
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


enum EasingPreset: String, CaseIterable {
    case smooth, snappy, linear, bouncy

    var easing: Easing {
        switch self {
        case .smooth: .default
        case .snappy: .cubicBezier(x1: 0.2, y1: 0, x2: 0, y2: 1)
        case .linear: .linear
        case .bouncy: .spring(.bouncy)
        }
    }

    init(_ easing: Easing) {
        self = Self.allCases.first { $0.easing == easing } ?? .smooth
    }
}

/// Edits every selected zoom at once (values shown are the first selected zoom's).
private struct SelectedZoomPanel: View {
    @Bindable var model: EditorModel
    let zoom: ZoomSegment
    let count: Int

    private var deadZone: Double {
        if case let .followCursor(d) = zoom.focus { d } else { 0.22 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader(count == 1 ? "Selected zoom" : "\(count) zooms selected") {
                Button("Deselect") { model.clearSelection() }.buttonStyle(.sc(.ghost, size: .small))
            }
            SCSlider(title: "Zoom level", value: value(\.scale, "Change Zoom Level"), in: 1.1...5, defaultValue: 2,
                     format: { String(format: "%.1f×", $0) })

            VStack(alignment: .leading, spacing: 7) {
                Text("Focus").font(Typo.label).foregroundStyle(Palette.textSecondary)
                SCSegmented(selection: Binding(
                    get: { zoom.focus.isFollow },
                    set: { follow in
                        if follow {
                            model.updateSelectedZooms("Follow Cursor") { $0.focus = .followCursor(deadZone: 0.22) }
                        } else {
                            model.updateSelectedZooms("Fixed Focus") { $0.focus = .fixed(.center) }
                            model.isPickingFocus = true
                        }
                    }
                ), options: [SCSegmentOption(true, "Follow cursor", icon: "scope"), SCSegmentOption(false, "Fixed point", icon: "plus.viewfinder")], fill: true)
            }
            if zoom.focus.isFollow {
                SCSlider(title: "Dead zone", value: Binding(
                    get: { deadZone },
                    set: { v in model.updateSelectedZooms("Change Dead Zone", coalesce: true) { $0.focus = .followCursor(deadZone: v) } }
                ), in: 0...0.45, defaultValue: 0.22, format: { $0 < 0.02 ? "Tight" : "\(Int($0 * 100))%" })
                VStack(alignment: .leading, spacing: 7) {
                    Text("Follow speed").font(Typo.label).foregroundStyle(Palette.textSecondary)
                    SCSegmented(selection: Binding(
                        get: { SpringPreset(zoom.followSpring) },
                        set: { p in model.updateSelectedZooms("Change Follow Speed") { $0.followSpring = p.params } }
                    ), options: [SpringPreset.gentle, .smooth, .snappy].map { SCSegmentOption($0, $0.rawValue.capitalized) }, fill: true)
                }
            } else {
                Button(model.isPickingFocus ? "Click the canvas…" : "Pick focus on canvas", systemImage: "scope") {
                    model.isPickingFocus.toggle()
                }
                .buttonStyle(.sc(model.isPickingFocus ? .primary : .secondary, size: .small))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Easing").font(Typo.label).foregroundStyle(Palette.textSecondary)
                SCSegmented(selection: Binding(
                    get: { EasingPreset(zoom.easing) },
                    set: { p in model.updateSelectedZooms("Change Easing") { $0.easing = p.easing } }
                ), options: EasingPreset.allCases.map { SCSegmentOption($0, $0.rawValue.capitalized) }, fill: true)
            }
            SCSlider(title: "Zoom in", value: value(\.transitionIn, "Change Zoom In"), in: 0...2, defaultValue: 0.7,
                     format: { String(format: "%.2f s", $0) })
            SCSlider(title: "Zoom out", value: value(\.transitionOut, "Change Zoom Out"), in: 0...2, defaultValue: 0.8,
                     format: { String(format: "%.2f s", $0) })
            Button(count == 1 ? "Delete Zoom" : "Delete \(count) Zooms", systemImage: "trash") { model.deleteSelection() }
                .buttonStyle(.sc(.destructive, size: .small))
        }
        .padding(12)
        .background(Palette.accentSoft.opacity(0.5), in: .rect(cornerRadius: Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Palette.accent.opacity(0.35)))
    }

    private func value(_ keyPath: WritableKeyPath<ZoomSegment, Double>, _ name: String) -> Binding<Double> {
        Binding(
            get: { zoom[keyPath: keyPath] },
            set: { v in model.updateSelectedZooms(name, coalesce: true) { $0[keyPath: keyPath] = v } }
        )
    }
}
