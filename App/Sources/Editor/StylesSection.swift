import SCCore
import SCProject
import SwiftUI

/// Saved looks: apply one in a click, save the current one, pick the default for new recordings.
struct StylesSection: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: EditorModel
    @State private var naming = false
    @State private var name = ""

    private var store: StyleStore { app.styles }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SCSectionHeader("Style") {
                Button("Save", systemImage: "plus") {
                    name = "Style \(store.presets.count + 1)"
                    naming = true
                }
                .buttonStyle(.sc(.ghost, size: .small))
                .help("Save this project's look as a style")
            }
            if naming {
                HStack(spacing: 6) {
                    SCTextField(placeholder: "Style name", text: $name, onSubmit: save)
                    Button("Save", action: save).buttonStyle(.sc(.primary, size: .small))
                    Button("Cancel", systemImage: "xmark") { naming = false }.buttonStyle(.scIcon(size: 26))
                }
                .onAppear { model.isEditingText = true }
                .onDisappear { model.isEditingText = false }
            }
            if store.presets.isEmpty && !naming {
                Text("Save a look to reuse it. The default style is applied to new recordings.")
                    .font(Typo.label).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.presets) { preset in
                StyleRow(preset: preset, isDefault: store.defaultID == preset.id, store: store, model: model)
            }
        }
    }

    private func save() {
        guard let project = model.project else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(name: trimmed.isEmpty ? "Style" : trimmed, from: project)
        naming = false
    }
}

private struct StyleRow: View {
    let preset: StylePreset
    let isDefault: Bool
    let store: StyleStore
    let model: EditorModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            preset.canvas.background.swiftUIView
                .frame(width: 34, height: 22)
                .clipShape(.rect(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.stroke))
            Text(preset.name).font(Typo.body).lineLimit(1)
            if isDefault { SCBadge(text: "Default") }
            Spacer(minLength: 4)
            if hovering {
                Button(isDefault ? "Stop using as default" : "Use for new recordings", systemImage: isDefault ? "star.fill" : "star") {
                    store.setDefault(isDefault ? nil : preset.id)
                }
                .buttonStyle(.scIcon(size: 22, active: isDefault))
                .help(isDefault ? "Stop using as default" : "Use for new recordings")
                Button("Update from project", systemImage: "arrow.triangle.2.circlepath") {
                    if let project = model.project { store.overwrite(preset.id, from: project) }
                }
                .buttonStyle(.scIcon(size: 22))
                .help("Replace this style with the project's current look")
                Button("Delete style", systemImage: "trash") { store.delete(preset.id) }
                    .buttonStyle(.scIcon(size: 22))
                    .help("Delete style")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(hovering ? Palette.canvas.opacity(0.6) : Palette.canvas.opacity(0.3), in: .rect(cornerRadius: Radius.m))
        .contentShape(.rect)
        .hoverState($hovering)
        .onTapGesture {
            model.update("Apply Style \(preset.name)") { preset.apply(to: &$0) }
        }
        .help("Click to apply")
    }
}
