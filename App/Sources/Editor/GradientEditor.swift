import SCCore
import SwiftUI

/// Edits a gradient: kind, color stops (drag to move, click the bar to add), angle, center, mesh colors.
struct GradientEditor: View {
    @Binding var spec: GradientSpec
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSegmented(selection: kindBinding, options: [
                SCSegmentOption(GradientSpec.Kind.linear, "Linear"), SCSegmentOption(.radial, "Radial"),
                SCSegmentOption(.angular, "Angular"), SCSegmentOption(.mesh, "Mesh"),
            ], fill: true)

            if spec.kind == .mesh {
                MeshEditor(spec: $spec)
            } else {
                StopBar(spec: $spec, selected: $selected)
                if spec.stops.indices.contains(selected) {
                    HStack(spacing: 10) {
                        SCColorWell(color: Binding(
                            get: { spec.stops[min(selected, spec.stops.count - 1)].color },
                            set: { c in if spec.stops.indices.contains(selected) { spec.stops[selected].color = c } }
                        ), size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Stop \(selected + 1)").font(Typo.label)
                            Text("\(Int(spec.stops[selected].location * 100))%").font(Typo.mono).foregroundStyle(Palette.textTertiary)
                        }
                        Spacer()
                        Button("Reverse", systemImage: "arrow.left.arrow.right") {
                            spec.stops = spec.stops.map { GradientStop(1 - $0.location, $0.color) }.sorted { $0.location < $1.location }
                        }
                        .buttonStyle(.scIcon(size: 26))
                        .help("Reverse colors")
                        Button("Remove stop", systemImage: "minus") {
                            spec.stops.remove(at: selected)
                            selected = max(selected - 1, 0)
                        }
                        .buttonStyle(.scIcon(size: 26))
                        .disabled(spec.stops.count <= 2)
                        .help("Remove this color stop")
                    }
                }
                if spec.kind != .radial {
                    SCSlider(title: "Angle", value: $spec.angle, in: -180...180, step: 1, defaultValue: 135, format: { "\(Int($0))°" })
                }
                if spec.kind != .linear {
                    SCSlider(title: "Center X", value: $spec.center.x, in: 0...1, defaultValue: 0.5, format: { "\(Int($0 * 100))%" })
                    SCSlider(title: "Center Y", value: $spec.center.y, in: 0...1, defaultValue: 0.5, format: { "\(Int($0 * 100))%" })
                }
            }
        }
    }

    private var kindBinding: Binding<GradientSpec.Kind> {
        Binding(get: { spec.kind }, set: { kind in
            var next = spec
            next.kind = kind
            if kind == .mesh, next.meshColors.count != 9 { next.meshColors = MeshEditor.meshFromStops(next.stops) }
            if kind != .mesh, next.stops.count < 2 { next.stops = GradientSpec.sunset.stops }
            spec = next
            selected = 0
        })
    }
}

/// Gradient preview bar with a draggable knob per stop.
private struct StopBar: View {
    @Binding var spec: GradientSpec
    @Binding var selected: Int
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                LinearGradient(stops: spec.stops.sorted { $0.location < $1.location }.map { .init(color: $0.color.color, location: $0.location) },
                               startPoint: .leading, endPoint: .trailing)
                    .clipShape(.rect(cornerRadius: Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(Palette.strokeStrong))
                    .frame(height: 22)
                    .contentShape(.rect)
                    .onTapGesture { p in addStop(at: min(max(p.x / w, 0), 1)) }
                    .help("Click to add a color stop")
                ForEach(spec.stops.indices, id: \.self) { i in
                    let stop = spec.stops[i]
                    Circle()
                        .fill(stop.color.color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: selected == i ? 3 : 2))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .scaleEffect(dragging == i ? 1.2 : 1)
                        .position(x: stop.location * w, y: 11)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            dragging = i
                            selected = i
                            if spec.stops.indices.contains(i) { spec.stops[i].location = min(max(g.location.x / w, 0), 1) }
                        }.onEnded { _ in dragging = nil })
                }
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 9)
        .animation(.spring(duration: 0.2), value: dragging)
    }

    private func addStop(at location: Double) {
        let sorted = spec.stops.sorted { $0.location < $1.location }
        let before = sorted.last { $0.location <= location } ?? sorted.first!
        let after = sorted.first { $0.location >= location } ?? sorted.last!
        let span = after.location - before.location
        let f = span > 0 ? (location - before.location) / span : 0
        let c = before.color, d = after.color
        let color = RGBAColor(c.r + (d.r - c.r) * f, c.g + (d.g - c.g) * f, c.b + (d.b - c.b) * f, 1)
        spec.stops.append(GradientStop(location, color))
        selected = spec.stops.count - 1
    }
}

/// 3×3 grid of colors for mesh gradients, plus shuffle.
struct MeshEditor: View {
    @Binding var spec: GradientSpec

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { col in
                            let i = row * 3 + col
                            SCColorWell(color: Binding(
                                get: { spec.meshColors.indices.contains(i) ? spec.meshColors[i] : .white },
                                set: { c in if spec.meshColors.indices.contains(i) { spec.meshColors[i] = c } }
                            ), size: 30)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Shuffle", systemImage: "shuffle") { spec.meshColors = Self.random(vivid: false) }
                    .buttonStyle(.sc(.secondary, size: .small))
                Button("Vivid", systemImage: "sparkles") { spec.meshColors = Self.random(vivid: true) }
                    .buttonStyle(.sc(.secondary, size: .small))
                Text("Tap a color to change it.").font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    /// Harmonious mesh: neighbouring hues around a random base.
    static func random(vivid: Bool) -> [RGBAColor] {
        let base = Double.random(in: 0..<1)
        return (0..<9).map { i in
            let h = (base + Double(i % 3) * 0.06 + Double(i / 3) * 0.05 + Double.random(in: -0.03...0.03)).truncatingRemainder(dividingBy: 1)
            let s = vivid ? Double.random(in: 0.65...0.9) : Double.random(in: 0.25...0.5)
            let b = vivid ? Double.random(in: 0.8...1) : Double.random(in: 0.92...1)
            let ns = NSColor(hue: h, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB)!
            return RGBAColor(ns.redComponent, ns.greenComponent, ns.blueComponent)
        }
    }

    static func meshFromStops(_ stops: [GradientStop]) -> [RGBAColor] {
        guard let first = stops.first?.color, let last = stops.last?.color else { return random(vivid: false) }
        return (0..<9).map { i in
            let f = Double(i % 3 + i / 3) / 4
            return RGBAColor(first.r + (last.r - first.r) * f, first.g + (last.g - first.g) * f, first.b + (last.b - first.b) * f)
        }
    }
}
