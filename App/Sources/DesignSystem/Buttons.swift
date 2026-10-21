import SwiftUI

struct SCButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive, record }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        SCButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct SCButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SCButtonStyle.Kind
    let size: SCButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(size == .small ? Typo.label : Typo.bodyMedium)
            .labelStyle(SCLabelStyle())
            .padding(.horizontal, size == .small ? 9 : size == .large ? 18 : 12)
            .frame(height: size == .small ? 24 : size == .large ? 38 : 30)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: size == .large ? Radius.l : Radius.m))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: size == .large ? Radius.l : Radius.m).strokeBorder(Palette.stroke)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
            .contentShape(.rect)
            .hoverState($hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .record, .destructive: .white
        case .secondary: Palette.text
        case .ghost: hovering ? Palette.text : Palette.textSecondary
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        let hot = hovering && isEnabled
        switch kind {
        case .primary: return Palette.accent.opacity(pressed ? 0.8 : hot ? 0.92 : 1)
        case .record: return Palette.record.opacity(pressed ? 0.8 : hot ? 0.92 : 1)
        case .destructive: return Palette.record.opacity(pressed ? 0.35 : hot ? 0.3 : 0.22)
        case .secondary: return pressed ? Palette.pressed : hot ? Palette.hover : Palette.raised
        case .ghost: return pressed ? Palette.pressed : hot ? Palette.hover : .clear
        }
    }
}

/// Square icon-only button with hover background.
struct SCIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        SCIconButtonBody(configuration: configuration, size: size, isActive: isActive)
    }
}

private struct SCIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.48, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(isActive ? Palette.accent : hovering ? Palette.text : Palette.textSecondary)
            .background(
                isActive ? Palette.accentSoft : configuration.isPressed ? Palette.pressed : hovering ? Palette.hover : .clear,
                in: .rect(cornerRadius: Radius.m)
            )
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(.rect)
            .hoverState($hovering)
    }
}

struct SCLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == SCButtonStyle {
    static func sc(_ kind: SCButtonStyle.Kind = .secondary, size: SCButtonStyle.Size = .regular) -> SCButtonStyle {
        SCButtonStyle(kind: kind, size: size)
    }
}

extension ButtonStyle where Self == SCIconButtonStyle {
    static func scIcon(size: CGFloat = 28, active: Bool = false) -> SCIconButtonStyle {
        SCIconButtonStyle(size: size, isActive: active)
    }
}
