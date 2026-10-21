import SwiftUI

/// Design tokens. The app is dark-only: every surface and text color is defined here.
enum Palette {
    static let canvas = Color(hex: 0x0C0C0E)
    static let surface = Color(hex: 0x141417)
    static let raised = Color(hex: 0x1C1C20)
    static let hover = Color(hex: 0x26262B)
    static let pressed = Color(hex: 0x2E2E34)
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.13)

    static let text = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.56)
    static let textTertiary = Color.white.opacity(0.34)

    static let accent = Color(hex: 0xFF6A1F)
    static let accentSoft = accent.opacity(0.16)
    static let record = Color(hex: 0xFF3B30)
    static let success = Color(hex: 0x32D46B)
    static let warning = Color(hex: 0xFFB020)

    // Timeline track tints.
    static let trackVideo = Color(hex: 0x3A5BD9)
    static let trackZoom = Color(hex: 0x1FA58A)
    static let trackCamera = Color(hex: 0x8B5CF6)
    static let trackBlur = Color(hex: 0xC2417A)
}

enum Radius {
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
}

enum Typo {
    static let caption = Font.system(size: 11, weight: .medium)
    static let label = Font.system(size: 12, weight: .medium)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let title = Font.system(size: 15, weight: .semibold)
    static let largeTitle = Font.system(size: 26, weight: .semibold)
    static let section = Font.system(size: 10.5, weight: .semibold)
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    static let mono = Font.system(size: 12, weight: .medium).monospacedDigit()
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension View {
    /// Standard window treatment: dark, custom chrome, our canvas color behind everything.
    func appWindowStyle() -> some View {
        self
            .preferredColorScheme(.dark)
            .tint(Palette.accent)
            .foregroundStyle(Palette.text)
            .font(Typo.body)
            // macOS 26 blurs content under the title bar ("scroll pocket"); our title bar is opaque content.
            .scrollEdgeEffectHidden(true, for: .all)
            .background(Palette.canvas)
            .ignoresSafeArea(.container, edges: .top)
            .background(WindowChrome())
    }

    /// Hover tracking that animates a Bool binding.
    func hoverState(_ hovering: Binding<Bool>) -> some View {
        onHover { value in withAnimation(.easeOut(duration: 0.12)) { hovering.wrappedValue = value } }
    }
}
