import SwiftUI

/// Rounded surface used for grouped content.
struct SCPanel<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Palette.surface, in: .rect(cornerRadius: Radius.l))
            .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Palette.stroke))
    }
}

/// Section heading, with an optional (i) explanation and trailing controls.
struct SCSectionHeader: View {
    let title: String
    var info: String?
    var trailing: AnyView?

    init(_ title: String, info: String? = nil) { self.title = title; self.info = info }
    init(_ title: String, info: String? = nil, @ViewBuilder trailing: () -> some View) {
        self.title = title
        self.info = info
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Typo.sectionTitle)
                .foregroundStyle(Palette.text)
            if let info { SCInfo(info) }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 22)
    }
}

/// Small (i) icon that explains something in a popover on hover.
struct SCInfo: View {
    let text: String
    @State private var hovering = false
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovering ? Palette.textSecondary : Palette.textTertiary)
            .frame(width: 16, height: 16)
            .contentShape(.rect)
            .onHover { inside in
                hovering = inside
                if inside {
                    // Short delay so passing over the icon doesn't flash a popover.
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        if hovering { shown = true }
                    }
                } else {
                    shown = false
                }
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 230, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .preferredColorScheme(.dark)
            }
            .accessibilityLabel(text)
    }
}

/// Control label followed by an (i) explanation, for toggles.
struct SCInfoLabel: View {
    let title: String
    let info: String

    init(_ title: String, info: String) { self.title = title; self.info = info }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            SCInfo(info)
        }
    }
}

/// Label on the left, control on the right.
struct SCRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Typo.label).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 28)
    }
}

struct SCDivider: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Palette.stroke)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Small rounded status chip.
struct SCBadge: View {
    let text: String
    var color: Color = Palette.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(color.opacity(0.14), in: .capsule)
    }
}

/// Empty / placeholder state.
struct SCEmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 64, height: 64)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.xl))
                .overlay(RoundedRectangle(cornerRadius: Radius.xl).strokeBorder(Palette.stroke))
            Text(title).font(Typo.title)
            Text(message).font(Typo.body).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
            HStack(spacing: 8) { actions }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Custom title bar that replaces the native toolbar. Leaves room for the traffic lights
/// and lets the user drag the window from its background.
struct SCTitleBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    /// Matches the unified title bar height set up by `WindowChrome`.
    static var height: CGFloat { 52 }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 12)
                trailing
            }
            center
        }
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .frame(height: Self.height)
    }
}

extension SCTitleBar where Center == EmptyView {
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: leading, center: { EmptyView() }, trailing: trailing)
    }
}
