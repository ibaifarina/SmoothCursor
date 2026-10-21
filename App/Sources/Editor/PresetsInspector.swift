import SCCore
import SCProject
import SwiftUI

/// Saved editor settings: pick which parts to save, apply in a click, choose one for new recordings.
struct PresetsInspector: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: EditorModel
    @State private var naming = false
    @State private var name = ""
    @State private var groups = Set(StylePreset.Group.allCases).subtracting([.mockup])
    @State private var applied: String?

    private var store: StyleStore { app.styles }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SCSectionHeader("Presets") {
                if !naming {
                    Button("New", systemImage: "plus") {
                        name = "Preset \(store.presets.count + 1)"
                        groups = Set(StylePreset.Group.allCases).subtracting(model.project?.mockup.isEnabled == true ? [] : [.mockup])
                        naming = true
                    }
                    .buttonStyle(.sc(.ghost, size: .small))
                    .help("Save this project's settings as a preset")
                }
            }
            if naming {
                saveForm
            } else if store.presets.isEmpty {
                Text("Save this project's settings to reuse them on other recordings. The default preset is applied to every new recording.")
                    .font(Typo.label).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let applied {
                Text("Applied “\(applied)”. ⌘Z to undo.").font(Typo.label).foregroundStyle(Palette.textSecondary)
            }
            ForEach(store.presets) { preset in
                PresetRow(preset: preset, isDefault: store.defaultID == preset.id, store: store, model: model) {
                    model.update("Apply Preset \(preset.name)") { preset.apply(to: &$0) }
                    applied = preset.name
                }
            }
        }
    }

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SCTextField(placeholder: "Preset name", text: $name, onSubmit: save)
            Text("Include").font(Typo.label).foregroundStyle(Palette.textSecondary)
            GroupChecklist(groups: $groups)
            HStack {
                Button("Cancel") { naming = false }.buttonStyle(.sc(.ghost, size: .small))
                Spacer()
                Button("Save Preset", action: save)
                    .buttonStyle(.sc(.primary, size: .small))
                    .disabled(groups.isEmpty)
            }
        }
        .padding(12)
        .background(Palette.accentSoft.opacity(0.5), in: .rect(cornerRadius: Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Palette.accent.opacity(0.35)))
        .onAppear { model.isEditingText = true }
        .onDisappear { model.isEditingText = false }
    }

    private func save() {
        guard let project = model.project, !groups.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(name: trimmed.isEmpty ? "Preset" : trimmed, from: project, groups: groups)
        naming = false
    }
}

/// Custom checkboxes, one per setting group.
private struct GroupChecklist: View {
    @Binding var groups: Set<StylePreset.Group>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(StylePreset.Group.allCases, id: \.self) { group in
                CheckRow(title: group.title, icon: group.symbol, isOn: groups.contains(group)) {
                    if groups.contains(group) { groups.remove(group) } else { groups.insert(group) }
                }
            }
        }
    }
}

private struct CheckRow: View {
    let title: String
    let icon: String
    let isOn: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Palette.accent : Palette.canvas.opacity(0.6))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isOn ? Palette.accent : hovering ? Palette.strokeStrong : Palette.stroke)
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.textTertiary).frame(width: 16)
                Text(title).font(Typo.body).foregroundStyle(isOn ? Palette.text : Palette.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(hovering ? Palette.canvas.opacity(0.5) : .clear, in: .rect(cornerRadius: Radius.s))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
        .animation(.easeOut(duration: 0.1), value: isOn)
    }
}

private struct PresetRow: View {
    let preset: StylePreset
    let isDefault: Bool
    let store: StyleStore
    let model: EditorModel
    let apply: () -> Void
    @State private var hovering = false
    @State private var editing = false

    private var summary: String {
        let groups = StylePreset.Group.allCases.filter { preset.includedGroups.contains($0) }
        if groups.count == StylePreset.Group.allCases.count { return "All settings" }
        return groups.map(\.title).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                preset.canvas.background.swiftUIView
                    .frame(width: 34, height: 24)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.stroke))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.name).font(Typo.body).lineLimit(1)
                        if isDefault { SCBadge(text: "Default") }
                    }
                    Text(summary).font(Typo.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovering || editing {
                    Button("Apply", action: apply).buttonStyle(.sc(.primary, size: .small))
                    Button("Edit preset", systemImage: "slider.horizontal.3") { editing.toggle() }
                        .buttonStyle(.scIcon(size: 22, active: editing))
                        .help("Choose what this preset includes")
                }
            }
            if editing {
                GroupChecklist(groups: Binding(
                    get: { preset.includedGroups },
                    set: { store.setGroups(preset.id, $0) }
                ))
                HStack(spacing: 6) {
                    Button(isDefault ? "Default" : "Make Default", systemImage: isDefault ? "star.fill" : "star") {
                        store.setDefault(isDefault ? nil : preset.id)
                    }
                    .help(isDefault ? "Stop applying this preset to new recordings" : "Apply this preset to every new recording")
                    Button("Update", systemImage: "arrow.triangle.2.circlepath") {
                        if let project = model.project { store.overwrite(preset.id, from: project) }
                    }
                    .help("Replace the saved values with this project's current settings")
                    Spacer()
                    Button("Delete preset", systemImage: "trash") { store.delete(preset.id) }
                        .buttonStyle(.scIcon(size: 24))
                        .help("Delete preset")
                }
                .buttonStyle(.sc(.secondary, size: .small))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hovering || editing ? Palette.canvas.opacity(0.6) : Palette.canvas.opacity(0.3), in: .rect(cornerRadius: Radius.m))
        .contentShape(.rect)
        .hoverState($hovering)
        .onTapGesture(count: 2, perform: apply)
        .help("Double-click to apply")
    }
}
