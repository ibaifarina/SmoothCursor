import SCCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: EditorModel

    /// The cursor tab needs cursor data; without it the panel falls back to the background.
    private var tab: InspectorTab {
        model.inspectorTab == .cursor && model.telemetry == nil ? .background : model.inspectorTab
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(tab.title).font(Typo.title)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                SCDivider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id("top")
                            // Each top-level piece of a tab is a section, separated by hairlines.
                            Group(subviews: content) { sections in
                                ForEach(sections) { section in
                                    section
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if section.id != sections.last?.id { SCDivider() }
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.never)
                    // Selecting something shows its settings, which sit at the top of the panel.
                    .onChange(of: model.selectedShots) { _, ids in
                        if !ids.isEmpty { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("top", anchor: .top) } }
                    }
                    .onChange(of: model.selectedZooms) { _, ids in
                        if !ids.isEmpty { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("top", anchor: .top) } }
                    }
                    .onChange(of: model.selectedBlurs) { _, ids in
                        if !ids.isEmpty { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("top", anchor: .top) } }
                    }
                }
            }
            SCDivider(vertical: true)
            VStack(spacing: 4) {
                ForEach(InspectorTab.allCases) { item in
                    let unavailable = item == .cursor && model.telemetry == nil
                    Button(item.title, systemImage: item.symbol) {
                        withAnimation(.easeOut(duration: 0.15)) { model.inspectorTab = item }
                    }
                    .buttonStyle(.scIcon(size: 32, active: tab == item))
                    .disabled(unavailable)
                    .help(unavailable ? "Cursor: this video has no cursor data" : item.title)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .background: BackgroundInspector(model: model)
        case .cursor: CursorInspector(model: model)
        case .zoom: ZoomInspector(model: model)
        case .mockup: MockupInspector(model: model)
        case .overlays: OverlaysInspector(model: model)
        case .presets: PresetsInspector(model: model)
        case .export: ExportInspector(model: model)
        }
    }
}

struct Swatch: View {
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
