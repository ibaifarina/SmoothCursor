import SwiftUI

// MARK: - Segmented

struct SCSegmentOption<Value: Hashable>: Identifiable {
    var value: Value
    var title: String?
    var icon: String?
    var id: Value { value }

    init(_ value: Value, _ title: String? = nil, icon: String? = nil) {
        self.value = value; self.title = title; self.icon = icon
    }
}

/// Pill segmented control with a sliding selection.
struct SCSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SCSegmentOption<Value>]
    var fill = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(duration: 0.28, bounce: 0.15)) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        if let icon = option.icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                        if let title = option.title { Text(title).lineLimit(1).minimumScaleFactor(0.75) }
                    }
                    .font(Typo.label)
                    .foregroundStyle(selected ? Palette.text : Palette.textSecondary)
                    .padding(.horizontal, fill ? 4 : 10)
                    .frame(maxWidth: fill ? .infinity : nil, minHeight: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Radius.s)
                                .fill(Palette.hover)
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Palette.canvas.opacity(0.7), in: .rect(cornerRadius: Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.stroke))
    }
}

// MARK: - Switch

struct SCSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SCSwitchBody(configuration: configuration)
    }
}

private struct SCSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                configuration.label
                    .font(Typo.label)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Capsule()
                    .fill(configuration.isOn ? Palette.accent : Palette.hover)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ToggleStyle where Self == SCSwitchStyle {
    static var scSwitch: SCSwitchStyle { SCSwitchStyle() }
}

// MARK: - Slider

/// Slider with a title, live value readout, fill track and double-click-to-reset.
struct SCSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var defaultValue: Double?
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var onEditingChanged: (Bool) -> Void = { _ in }

    init(
        title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
        defaultValue: Double? = nil, format: @escaping (Double) -> String = { String(format: "%.2f", $0) },
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.title = title; self._value = value; self.range = range; self.step = step
        self.defaultValue = defaultValue; self.format = format; self.onEditingChanged = onEditingChanged
    }

    @Environment(\.isEnabled) private var isEnabled
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(format(value)).font(Typo.mono).foregroundStyle(dragging ? Palette.text : Palette.textSecondary)
            }
            .font(Typo.label)
            GeometryReader { geo in
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = geo.size.width * min(max(fraction, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hover).frame(height: 4)
                    Capsule().fill(Palette.accent).frame(width: x, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: dragging ? 15 : hovering ? 14 : 12, height: dragging ? 15 : hovering ? 14 : 12)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: x - (dragging ? 7.5 : hovering ? 7 : 6))
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !dragging { dragging = true; onEditingChanged(true) }
                            set(fraction: g.location.x / max(geo.size.width, 1))
                        }
                        .onEnded { _ in dragging = false; onEditingChanged(false) }
                )
                .onTapGesture(count: 2) { if let defaultValue { value = defaultValue } }
            }
            .frame(height: 16)
            .hoverState($hovering)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.12), value: dragging)
    }

    private func set(fraction: Double) {
        var v = range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
        if let step { v = (v / step).rounded() * step }
        value = min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - Dropdown

struct SCDropdownOption<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var icon: String?
    var id: Value { value }
    init(_ value: Value, _ title: String, icon: String? = nil) {
        self.value = value; self.title = title; self.icon = icon
    }
}

/// Button that opens a custom list of options.
struct SCDropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SCDropdownOption<Value>]
    var icon: String?
    var minWidth: CGFloat = 120
    /// Stretch to the available width instead of hugging the label.
    var fill = false
    @State private var open = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var current: SCDropdownOption<Value>? { options.first { $0.value == selection } }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                if let icon = current?.icon ?? icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                }
                Text(current?.title ?? "—").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textTertiary)
            }
            .font(Typo.label)
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, minHeight: 28)
            .background(hovering || open ? Palette.hover : Palette.raised, in: .rect(cornerRadius: Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.stroke))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fill, vertical: false)
        .hoverState($hovering)
        .opacity(isEnabled ? 1 : 0.4)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SCMenuList(options: options, selection: selection) { value in
                selection = value
                open = false
            }
        }
    }
}

private struct SCMenuList<Value: Hashable>: View {
    let options: [SCDropdownOption<Value>]
    let selection: Value
    let choose: (Value) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(options) { option in
                    SCMenuRow(title: option.title, icon: option.icon, selected: option.value == selection) { choose(option.value) }
                }
            }
            .padding(5)
        }
        .frame(minWidth: 200, maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.raised)
        .preferredColorScheme(.dark)
    }
}

struct SCMenuRow: View {
    let title: String
    var icon: String?
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(selected ? 1 : 0).frame(width: 12)
                if let icon { Image(systemName: icon).font(.system(size: 12)).frame(width: 16) }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Typo.body)
            .foregroundStyle(hovering ? .white : Palette.text)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(hovering ? Palette.accent : .clear, in: .rect(cornerRadius: Radius.s))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Text field

struct SCTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.textTertiary) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Palette.canvas.opacity(0.6), in: .rect(cornerRadius: Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(focused ? Palette.accent.opacity(0.8) : Palette.stroke, lineWidth: focused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}
