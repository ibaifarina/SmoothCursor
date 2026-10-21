import SCCore
import SCRender
import SwiftUI

struct MockupInspector: View {
    @Bindable var model: EditorModel

    private var mockup: MockupSettings { model.project?.mockup ?? MockupSettings() }
    private var shots: [CameraClip] { (model.project?.cameraClips ?? []).sorted { $0.range.start < $1.range.start } }

    var body: some View {
        if mockup.isEnabled, let shot = selectedShot {
            SelectedShotPanel(model: model, shot: shot, count: model.selectedShots.count)
        }
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Device")
            SCSegmented(selection: Binding(get: { mockup.device }, set: { model.setMockup($0) }), options: [
                SCSegmentOption(MockupSettings.Device.none, "Flat", icon: "rectangle"),
                SCSegmentOption(.phone, "iPhone", icon: "iphone"),
            ], fill: true)
            if !mockup.isEnabled {
                Text("Put the recording on a 3D phone, with camera shots you place on the Camera track.")
                    .font(Typo.label).foregroundStyle(Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }

        if mockup.isEnabled {
            VStack(alignment: .leading, spacing: 10) {
                SCSectionHeader("Finish")
                HStack(spacing: 10) {
                    ForEach(MockupSettings.Finish.allCases, id: \.self) { finish in
                        FinishSwatch(finish: finish, selected: mockup.finish == finish) {
                            model.update("Change Finish") { $0.mockup.finish = finish }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SCSectionHeader("Lighting") {
                    Button("Reset") {
                        model.update("Reset Lighting") {
                            let d = MockupSettings()
                            $0.mockup.lightYaw = d.lightYaw; $0.mockup.lightPitch = d.lightPitch
                            $0.mockup.lightStrength = d.lightStrength; $0.mockup.shadowOpacity = d.shadowOpacity
                        }
                    }
                    .buttonStyle(.sc(.ghost, size: .small))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(MockupEnvironment.allCases, id: \.self) { env in
                        EnvironmentCard(environment: env, selected: mockup.environment == env.rawValue) {
                            model.update("Change Lighting") { $0.mockup.environment = env.rawValue }
                        }
                    }
                }
                SCSlider(title: "Yaw", value: model.binding(\.mockup.lightYaw, "Rotate Light"), in: 0...360, defaultValue: 150,
                         format: { "\(Int($0))°" })
                SCSlider(title: "Pitch", value: model.binding(\.mockup.lightPitch, "Tilt Light"), in: -40...30, defaultValue: 0,
                         format: { "\(Int($0))°" })
                SCSlider(title: "Light strength", value: model.binding(\.mockup.lightStrength, "Change Light Strength"), in: 0.3...2.5,
                         defaultValue: 1, format: { String(format: "%.1f", $0) })
                SCSlider(title: "Shadow", value: model.binding(\.mockup.shadowOpacity, "Change Shadow"), in: 0...1, defaultValue: 0.5,
                         format: { "\(Int($0 * 100))%" })
                SCSlider(title: "Screen reflections", value: model.binding(\.mockup.screenReflection, "Change Reflections"), in: 0...1,
                         defaultValue: 0.5, format: { "\(Int($0 * 100))%" })
            }

            VStack(alignment: .leading, spacing: 12) {
                SCSectionHeader("Camera") { SCBadge(text: "\(shots.count) shots") }
                Button("Auto camera", systemImage: "wand.and.stars") { model.autoCamera() }
                    .buttonStyle(.sc(.secondary, size: .small))
                    .help("Close-ups where the zooms are, varied shots in between. Replaces the current shots.")
                if model.selectedShots.isEmpty {
                    Text("Add a shot at the playhead:").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(CameraPreset.allCases, id: \.self) { preset in
                            ShotPresetButton(preset: preset, selected: false) { model.applyShot(preset) }
                        }
                    }
                }
            }

        }
    }

    private var selectedShot: CameraClip? { shots.first { model.selectedShots.contains($0.id) } }
}

private struct FinishSwatch: View {
    let finish: MockupSettings.Finish
    let selected: Bool
    let action: () -> Void

    private var colors: (Color, Color) {
        switch finish {
        case .black: (Color(hex: 0x55555A), Color(hex: 0x1E1E22))
        case .silver: (Color(hex: 0xE8E8EA), Color(hex: 0xB9B9BE))
        case .natural: (Color(hex: 0xC9C3B8), Color(hex: 0x8E8A82))
        case .desert: (Color(hex: 0xDCC3A3), Color(hex: 0xA48A6C))
        case .blue: (Color(hex: 0x5E6F8C), Color(hex: 0x2E3A52))
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Circle()
                    .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(selected ? Palette.accent : Palette.strokeStrong, lineWidth: selected ? 2 : 1).padding(-3))
                Text(finish.rawValue.capitalized).font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(selected ? Palette.text : Palette.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct EnvironmentCard: View {
    let environment: MockupEnvironment
    let selected: Bool
    let action: () -> Void
    @State private var image: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                FilledImage(image: image)
                    .frame(height: 38)
                    .clipShape(.rect(cornerRadius: Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(selected ? Palette.accent : Palette.stroke, lineWidth: selected ? 2 : 1))
                Text(environment.label).font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(selected ? Palette.text : Palette.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .task {
            if image == nil {
                image = await Task.detached(priority: .utility) { MockupPreviews.environmentThumbnail(environment) }.value
            }
        }
    }
}

private struct ShotPresetButton: View {
    let preset: CameraPreset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: preset.symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? .white : Palette.trackCamera)
                    .frame(width: 16)
                Text(preset.label).font(Typo.label).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(selected ? Palette.trackCamera.opacity(0.7) : hovering ? Palette.hover : Palette.raised, in: .rect(cornerRadius: Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Palette.stroke))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

private struct SelectedShotPanel: View {
    @Bindable var model: EditorModel
    let shot: CameraClip
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader(count == 1 ? "Selected shot · \(shot.range.start.clock)–\(shot.range.end.clock)" : "\(count) shots selected") {
                Button("Done") { model.clearSelection() }.buttonStyle(.sc(.ghost, size: .small))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(CameraPreset.allCases, id: \.self) { preset in
                    ShotPresetButton(preset: preset, selected: shot.preset == preset) { model.applyShot(preset) }
                }
            }
            SCSlider(title: "Motion", value: Binding(
                get: { shot.intensity },
                set: { v in model.updateSelectedShots("Change Shot Motion", coalesce: true) { $0.intensity = v } }
            ), in: 0...1, defaultValue: 0.5, format: { $0 < 0.05 ? "Still" : "\(Int($0 * 100))%" })
            SCSlider(title: "Transition", value: Binding(
                get: { shot.transition },
                set: { v in model.updateSelectedShots("Change Transition", coalesce: true) { $0.transition = v } }
            ), in: 0...2.5, defaultValue: 0.8, format: { String(format: "%.1f s", $0) })
            VStack(alignment: .leading, spacing: 7) {
                Text("Easing").font(Typo.label).foregroundStyle(Palette.textSecondary)
                SCSegmented(selection: Binding(
                    get: { EasingPreset(shot.easing) },
                    set: { p in model.updateSelectedShots("Change Easing") { $0.easing = p.easing } }
                ), options: EasingPreset.allCases.map { SCSegmentOption($0, $0.rawValue.capitalized) }, fill: true)
            }
            Button(count == 1 ? "Delete Shot" : "Delete \(count) Shots", systemImage: "trash") { model.deleteSelection() }
                .buttonStyle(.sc(.destructive, size: .small))
        }
        .padding(12)
        .background(Palette.trackCamera.opacity(0.1), in: .rect(cornerRadius: Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Palette.trackCamera.opacity(0.4)))
    }
}
