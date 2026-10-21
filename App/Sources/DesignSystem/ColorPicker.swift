import AppKit
import SCCore
import SwiftUI

/// Swatch button that opens `SCColorPicker` in a popover.
struct SCColorWell: View {
    @Binding var color: RGBAColor
    var size: CGFloat = 24
    var showsAlpha = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.color)
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open ? Palette.accent : Palette.strokeStrong, lineWidth: open ? 2 : 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .leading) {
            SCColorPicker(color: $color, showsAlpha: showsAlpha)
        }
    }
}

/// Hue/saturation/brightness picker with hex entry and a screen eyedropper.
struct SCColorPicker: View {
    @Binding var color: RGBAColor
    var showsAlpha = false

    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 1
    @State private var alpha: Double = 1
    @State private var hex = ""
    @State private var syncedFrom: RGBAColor?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            saturationBrightness
            hueBar
            if showsAlpha { alphaBar }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(color.color).frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.strokeStrong))
                SCTextField(placeholder: "#RRGGBB", text: $hex, icon: "number") { applyHex() }
                    .font(Typo.mono)
                Button("Pick from screen", systemImage: "eyedropper") { sample() }
                    .buttonStyle(.scIcon(size: 30))
                    .help("Pick a color from anywhere on screen")
            }
        }
        .padding(14)
        .frame(width: 252)
        .background(Palette.raised)
        .preferredColorScheme(.dark)
        .onAppear(perform: syncFromColor)
        .onChange(of: color) { if color != syncedFrom { syncFromColor() } }
    }

    private var saturationBrightness: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(hue: hue, saturation: 1, brightness: 1)
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(Color(hue: hue, saturation: saturation, brightness: brightness)))
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: saturation * geo.size.width, y: (1 - brightness) * geo.size.height)
            }
            .clipShape(.rect(cornerRadius: Radius.m))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                saturation = min(max(g.location.x / geo.size.width, 0), 1)
                brightness = 1 - min(max(g.location.y / geo.size.height, 0), 1)
                commit()
            })
        }
        .frame(height: 150)
    }

    private var hueBar: some View {
        track(
            fill: LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                                 startPoint: .leading, endPoint: .trailing),
            value: $hue
        )
    }

    private var alphaBar: some View {
        track(
            fill: LinearGradient(colors: [Color(hue: hue, saturation: saturation, brightness: brightness).opacity(0),
                                          Color(hue: hue, saturation: saturation, brightness: brightness)],
                                 startPoint: .leading, endPoint: .trailing),
            value: $alpha
        )
    }

    private func track(fill: LinearGradient, value: Binding<Double>) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(fill)
                Circle().strokeBorder(.white, lineWidth: 2.5)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: value.wrappedValue * (geo.size.width - 16))
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value.wrappedValue = min(max((g.location.x - 8) / (geo.size.width - 16), 0), 1)
                commit()
            })
        }
        .frame(height: 16)
    }

    private func commit() {
        let ns = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha).usingColorSpace(.sRGB)!
        let new = RGBAColor(ns.redComponent, ns.greenComponent, ns.blueComponent, showsAlpha ? alpha : color.a)
        syncedFrom = new
        color = new
        hex = new.hex
    }

    private func syncFromColor() {
        let ns = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Keep the hue when the color is grey (hue is undefined there).
        if s > 0.001 && b > 0.001 { hue = h }
        saturation = s
        brightness = b
        alpha = a
        hex = color.hex
        syncedFrom = color
    }

    private func applyHex() {
        guard let parsed = RGBAColor(hexString: hex, alpha: color.a) else { hex = color.hex; return }
        color = parsed
        syncFromColor()
    }

    private func sample() {
        NSColorSampler().show { picked in
            guard let picked = picked?.usingColorSpace(.sRGB) else { return }
            Task { @MainActor in
                color = RGBAColor(picked.redComponent, picked.greenComponent, picked.blueComponent, color.a)
                syncFromColor()
            }
        }
    }
}

extension RGBAColor {
    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    init?(hexString: String, alpha: Double = 1) {
        let s = hexString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v, alpha: alpha)
    }
}
