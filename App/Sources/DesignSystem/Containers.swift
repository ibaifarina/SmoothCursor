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

/// Small uppercase section heading.
struct SCSectionHeader: View {
    let title: String
    var trailing: AnyView?

    init(_ title: String) { self.title = title }
    init(_ title: String, @ViewBuilder trailing: () -> some View) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(Typo.section)
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            trailing
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
