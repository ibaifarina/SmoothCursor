import SCCore
import SCProject
import SwiftUI

/// Keystrokes, captions, blur regions and the webcam bubble.
struct OverlaysInspector: View {
    @Bindable var model: EditorModel
    @State private var languages: [Locale] = []
    @State private var language = Locale.current.identifier(.bcp47)

    private var project: Project? { model.project }

    var body: some View {
        if let project {
            keystrokes(project)
            captions(project)
            redactions(project)
            if project.recording.cameraFile != nil { webcam(project) }
        }
    }

    // MARK: Keystrokes

    @ViewBuilder private func keystrokes(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Keystrokes")
            if !model.hasKeyData {
                note("keyboard", "No keys were recorded. Keystrokes need Accessibility access while recording.")
            }
            Toggle("Show shortcuts", isOn: model.binding(\.keystrokes.enabled, "Toggle Keystrokes", coalesce: false))
                .toggleStyle(.scSwitch)
            Group {
                Toggle("Include typing", isOn: model.binding(\.keystrokes.showTyping, "Toggle Typing", coalesce: false))
                    .toggleStyle(.scSwitch)
                    .help("Shows typed text too. Check the video for passwords before sharing.")
                positionPicker(model.binding(\.keystrokes.position, "Move Keystrokes", coalesce: false))
                SCSegmented(
                    selection: model.binding(\.keystrokes.lightStyle, "Change Keystroke Style", coalesce: false),
                    options: [SCSegmentOption(false, "Dark"), SCSegmentOption(true, "Light")],
                    fill: true
                )
                SCSlider(title: "Size", value: model.binding(\.keystrokes.size, "Change Keystroke Size"), in: 0.6...1.8,
                         defaultValue: 1, format: { "\(Int($0 * 100))%" })
            }
            .disabled(!project.keystrokes.enabled)
        }
        .disabled(!model.hasKeyData)
    }

    // MARK: Captions

    @ViewBuilder private func captions(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Captions") {
                if !project.captionSegments.isEmpty {
                    Toggle("Show captions", isOn: model.binding(\.captions.enabled, "Toggle Captions", coalesce: false))
                        .toggleStyle(.scSwitch).labelsHidden()
                }
            }
            HStack(spacing: 8) {
                SCDropdown(
                    selection: $language,
                    options: languageOptions,
                    icon: "globe", fill: true
                )
                Button(project.captionSegments.isEmpty ? "Generate" : "Redo") {
                    Task { await model.generateCaptions(language: language) }
                }
                .buttonStyle(.sc(.primary))
                .disabled(model.captionStatus != nil)
            }
            if let status = model.captionStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(Typo.label).foregroundStyle(Palette.textSecondary)
                }
            } else if let error = model.captionError {
                note("exclamationmark.triangle", error)
            } else if project.captionSegments.isEmpty {
                Text("Transcribed on this Mac. Nothing leaves your computer.")
                    .font(Typo.label).foregroundStyle(Palette.textTertiary)
            }

            if !project.captionSegments.isEmpty {
                Group {
                    positionPicker(model.binding(\.captions.position, "Move Captions", coalesce: false))
                    SCSegmented(
                        selection: model.binding(\.captions.boxed, "Change Caption Style", coalesce: false),
                        options: [SCSegmentOption(true, "Box"), SCSegmentOption(false, "Shadow")],
                        fill: true
                    )
                    SCSlider(title: "Size", value: model.binding(\.captions.size, "Change Caption Size"), in: 0.6...1.8,
                             defaultValue: 1, format: { "\(Int($0 * 100))%" })
                    VStack(spacing: 4) {
                        ForEach(project.captionSegments) { segment in
                            CaptionRow(model: model, segment: segment)
                        }
                    }
                }
                .disabled(!project.captions.enabled)
            }
        }
        .task {
            languages = await Transcriber.supportedLanguages()
            if let saved = project.captions.language { language = saved }
        }
    }

    private var languageOptions: [SCDropdownOption<String>] {
        var ids = languages.map { $0.identifier(.bcp47) }
        if !ids.contains(language) { ids.insert(language, at: 0) }
        return ids.map { id in
            SCDropdownOption(id, Locale.current.localizedString(forIdentifier: id) ?? id)
        }
    }

    // MARK: Blur regions

    @ViewBuilder private func redactions(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Blur") {
                Button(model.isDrawingRedaction ? "Cancel" : "Add", systemImage: model.isDrawingRedaction ? "xmark" : "plus") {
                    model.isPickingFocus = false
                    model.isDrawingRedaction.toggle()
                }
                .buttonStyle(.sc(.ghost, size: .small))
                .disabled(project.mockup.isEnabled)
            }
            if project.mockup.isEnabled {
                note("iphone", "Turn off the 3D phone to draw blur regions.")
            } else if model.isDrawingRedaction {
                note("rectangle.dashed", "Drag on the video over what should be hidden.")
            } else if project.redactions.isEmpty {
                Text("Hide passwords, emails and other private details.")
                    .font(Typo.label).foregroundStyle(Palette.textTertiary)
            }
            ForEach(project.redactions) { region in
                RedactionRow(model: model, region: region, index: (project.redactions.firstIndex(of: region) ?? 0) + 1)
            }
        }
    }

    // MARK: Webcam

    @ViewBuilder private func webcam(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SCSectionHeader("Camera") {
                Toggle("Show camera", isOn: model.binding(\.webcam.visible, "Toggle Camera", coalesce: false))
                    .toggleStyle(.scSwitch).labelsHidden()
            }
            Group {
                SCSegmented(
                    selection: model.binding(\.webcam.shape, "Change Camera Shape", coalesce: false),
                    options: [SCSegmentOption(WebcamSettings.Shape.circle, "Circle", icon: "circle"),
                              SCSegmentOption(.rounded, "Rounded", icon: "app")],
                    fill: true
                )
                VStack(alignment: .leading, spacing: 7) {
                    Text("Corner").font(Typo.label).foregroundStyle(Palette.textSecondary)
                    SCSegmented(
                        selection: model.binding(\.webcam.corner, "Move Camera", coalesce: false),
                        options: [
                            SCSegmentOption(Corner.topLeft, icon: "arrow.up.left"),
                            SCSegmentOption(.topRight, icon: "arrow.up.right"),
                            SCSegmentOption(.bottomLeft, icon: "arrow.down.left"),
                            SCSegmentOption(.bottomRight, icon: "arrow.down.right"),
                        ],
                        fill: true
                    )
                }
                SCSlider(title: "Size", value: model.binding(\.webcam.size, "Change Camera Size"), in: 0.12...0.45,
                         defaultValue: 0.24, format: { "\(Int($0 * 100))%" })
                Toggle("Mirror", isOn: model.binding(\.webcam.mirror, "Toggle Mirror", coalesce: false))
                    .toggleStyle(.scSwitch)
                Toggle("Shrink while zoomed", isOn: model.binding(\.webcam.shrinkDuringZoom, "Toggle Camera Shrink", coalesce: false))
                    .toggleStyle(.scSwitch)
            }
            .disabled(!project.webcam.visible)
        }
    }

    // MARK: Pieces

    private func positionPicker(_ binding: Binding<OverlayPosition>) -> some View {
        SCSegmented(
            selection: binding,
            options: [SCSegmentOption(OverlayPosition.bottom, "Bottom", icon: "rectangle.bottomhalf.filled"),
                      SCSegmentOption(.top, "Top", icon: "rectangle.tophalf.filled")],
            fill: true
        )
    }

    private func note(_ icon: String, _ text: String) -> some View {
        SCPanel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(Palette.textTertiary)
                Text(text).font(Typo.label).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One caption line: click the time to jump there, edit the text in place.
private struct CaptionRow: View {
    @Bindable var model: EditorModel
    let segment: CaptionSegment
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var isCurrent: Bool { segment.range.contains(model.playback?.time ?? -1) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(timestamp(segment.range.start)) { model.playback?.seek(to: segment.range.start + 0.01) }
                .buttonStyle(.plain)
                .font(Typo.mono)
                .foregroundStyle(isCurrent ? Palette.accent : Palette.textTertiary)
            TextField("Caption", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .focused($focused)
                .onSubmit(commit)
            if hovering {
                Button("Delete caption", systemImage: "trash") {
                    model.update("Delete Caption") { $0.captionSegments.removeAll { $0.id == segment.id } }
                }
                .buttonStyle(.scIcon(size: 20))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isCurrent ? Palette.accent.opacity(0.1) : hovering ? Palette.canvas.opacity(0.5) : .clear,
                    in: .rect(cornerRadius: Radius.s))
        .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(focused ? Palette.accent.opacity(0.7) : .clear))
        .hoverState($hovering)
        .onAppear { text = segment.text }
        .onChange(of: segment.text) { _, t in if !focused { text = t } }
        .onChange(of: focused) { _, f in
            model.isEditingText = f
            if !f { commit() }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != segment.text else { return }
        model.update("Edit Caption", coalesce: false) { p in
            guard let i = p.captionSegments.firstIndex(where: { $0.id == segment.id }) else { return }
            if trimmed.isEmpty { p.captionSegments.remove(at: i) } else { p.captionSegments[i].text = trimmed }
        }
    }

    private func timestamp(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct RedactionRow: View {
    @Bindable var model: EditorModel
    let region: RedactRegion
    let index: Int

    var body: some View {
        SCPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: region.style == .blur ? "drop.halffull" : "squareshape.split.3x3")
                        .foregroundStyle(Palette.textSecondary)
                    Text("Region \(index)").font(Typo.label)
                    Spacer()
                    Button("Delete region", systemImage: "trash") {
                        model.update("Delete Blur Region") { $0.redactions.removeAll { $0.id == region.id } }
                    }
                    .buttonStyle(.scIcon(size: 22))
                }
                SCSegmented(
                    selection: Binding(
                        get: { region.style },
                        set: { style in edit("Change Blur Style") { $0.style = style } }
                    ),
                    options: [SCSegmentOption(RedactRegion.Style.blur, "Blur"), SCSegmentOption(.pixelate, "Pixelate")],
                    fill: true
                )
                HStack(spacing: 6) {
                    Button("Start \(time(region.range.start))", systemImage: "arrow.right.to.line") {
                        let t = model.playback?.time ?? 0
                        edit("Set Blur Start") { $0.range.start = min(t, $0.range.end - 0.1) }
                    }
                    .help("Start at the playhead")
                    Button("End \(time(region.range.end))", systemImage: "arrow.left.to.line") {
                        let t = model.playback?.time ?? 0
                        edit("Set Blur End") { $0.range.end = max(t, $0.range.start + 0.1) }
                    }
                    .help("End at the playhead")
                }
                .buttonStyle(.sc(.secondary, size: .small))
            }
        }
    }

    private func edit(_ name: String, _ change: @escaping (inout RedactRegion) -> Void) {
        model.update(name, coalesce: false) { p in
            guard let i = p.redactions.firstIndex(where: { $0.id == region.id }) else { return }
            change(&p.redactions[i])
        }
    }

    private func time(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// Volume per audio track, plus the synthesized click sound.
struct AudioInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        if let project = model.project {
            VStack(alignment: .leading, spacing: 14) {
                SCSectionHeader("Tracks")
                if model.audioTrackNames.isEmpty {
                    Text("This recording has no audio.").font(Typo.label).foregroundStyle(Palette.textTertiary)
                }
                ForEach(Array(model.audioTrackNames.enumerated()), id: \.offset) { i, name in
                    track(i, name, project.audio)
                }
                if !model.audioTrackNames.isEmpty {
                    SCSlider(title: "Master", value: model.binding(\.audio.master, "Change Volume"), in: 0...2,
                             defaultValue: 1, format: percent)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                SCSectionHeader("Effects")
                Toggle("Click sound", isOn: model.binding(\.cursor.clickSound, "Toggle Click Sound", coalesce: false))
                    .toggleStyle(.scSwitch)
                    .disabled(model.telemetry == nil)
                SCSlider(title: "Click volume", value: model.binding(\.cursor.clickVolume, "Change Click Volume"), in: 0...2,
                         defaultValue: 1, format: { "\(Int(($0 * 100).rounded()))%" })
                    .disabled(!(model.project?.cursor.clickSound ?? false) || model.telemetry == nil)
            }

            VStack(alignment: .leading, spacing: 10) {
                SCSectionHeader("Trim")
                Button("Remove idle parts", systemImage: "scissors") { model.trimIdle() }
                    .buttonStyle(.sc(.secondary))
                    .help("Cuts stretches longer than 2.5 s with no movement, input or sound")
                if let message = model.idleTrimMessage {
                    Text(message).font(Typo.label).foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func track(_ i: Int, _ name: String, _ audio: AudioSettings) -> some View {
        let muted = audio.muted.indices.contains(i) && audio.muted[i]
        return HStack(alignment: .bottom, spacing: 10) {
            SCSlider(
                title: name,
                value: Binding(
                    get: { audio.volumes.indices.contains(i) ? audio.volumes[i] : 1 },
                    set: { v in
                        model.update("Change Volume", coalesce: true) { p in
                            while p.audio.volumes.count <= i { p.audio.volumes.append(1) }
                            p.audio.volumes[i] = v
                        }
                    }
                ),
                in: 0...2, defaultValue: 1, format: percent
            )
            .disabled(muted)
            Button(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                model.update(muted ? "Unmute Track" : "Mute Track", coalesce: false) { p in
                    while p.audio.muted.count <= i { p.audio.muted.append(false) }
                    p.audio.muted[i].toggle()
                }
            }
            .buttonStyle(.scIcon(size: 26, active: muted))
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}
