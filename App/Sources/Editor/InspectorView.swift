import SCCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 0).id("top")
                        content
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                // Selecting something shows its settings, which sit at the top of the panel.
                .onChange(of: model.selectedShots) { _, ids in
                    if !ids.isEmpty { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("top", anchor: .top) } }
                }
                .onChange(of: model.selectedZooms) { _, ids in
                    if !ids.isEmpty { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("top", anchor: .top) } }
                }
            }
            SCDivider(vertical: true)
            VStack(spacing: 4) {
                ForEach(InspectorTab.allCases) { tab in
                    Button(tab.title, systemImage: tab.symbol) {
                        withAnimation(.easeOut(duration: 0.15)) { model.inspectorTab = tab }
                    }
                    .buttonStyle(.scIcon(size: 32, active: model.inspectorTab == tab))
                    .help(tab.title)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.inspectorTab {
        case .background: BackgroundInspector(model: model)
        case .cursor: CursorInspector(model: model)
        case .zoom: ZoomInspector(model: model)
        case .mockup: MockupInspector(model: model)
        case .export: ExportInspector(model: model)
        }
    }

    private func comingSoon(_ title: String, step: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SCSectionHeader(title)
            SCPanel {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(Palette.textTertiary)
                    Text("Arrives in step \(step).").font(Typo.label).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
