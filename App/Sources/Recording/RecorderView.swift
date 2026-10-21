import SCCapture
import SCCore
import SwiftUI

/// "New Recording" window: source, audio, quality, then Record.
struct RecorderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var recorder: RecordingController { app.recorder }

    var body: some View {
        @Bindable var recorder = recorder
        VStack(spacing: 0) {
            SCTitleBar {
                Text("New Recording").font(Typo.title)
            } trailing: {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .buttonStyle(.scIcon())
                    .help("Refresh sources")
            }
            VStack(alignment: .leading, spacing: 16) {
                if !app.permissions.allRequiredGranted {
                    SCPanel(padding: 12) {
                        PermissionRow(kind: .screenRecording, status: app.permissions.status(.screenRecording)) {
                            Task { await app.permissions.request(.screenRecording) }
                        }
                    }
                }

                SCSegmented(
                    selection: $recorder.sourceKind,
                    options: SourceKind.allCases.map { SCSegmentOption($0, $0.title, icon: $0.symbol) },
                    fill: true
                )

                SourcePicker(recorder: recorder)
                    .frame(height: 248)

                SCDivider()
                AudioSection(recorder: recorder)
                SCDivider()
                QualitySection(recorder: recorder)
                SCDivider()
                footer
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 640)
        .task { await refresh() }
        .onChange(of: recorder.sourceKind) { recorder.validateTarget() }
        .onChange(of: app.permissions.allRequiredGranted) { Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onChange(of: recorder.phase) { _, phase in
            if phase.isActive { dismissWindow(id: WindowID.recorder) }
        }
        .onAppear {
            recorder.openEditor = { openWindow(id: WindowID.editor, value: $0) }
            recorder.openRecorder = { openWindow(id: WindowID.recorder) }
        }
        .alert("Recording failed", isPresented: .init(
            get: { recorder.errorMessage != nil }, set: { if !$0 { recorder.errorMessage = nil } }
        )) { Button("OK") {} } message: { Text(recorder.errorMessage ?? "") }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                KeyCap("⌥⇧⌘R")
                Text("start / stop").foregroundStyle(Palette.textTertiary)
                KeyCap("⌥⇧⌘P").padding(.leading, 6)
                Text("pause").foregroundStyle(Palette.textTertiary)
            }
            .font(Typo.caption)
            Spacer()
            Button("Record", systemImage: "record.circle.fill") { recorder.start() }
                .buttonStyle(.sc(.record, size: .large))
                .keyboardShortcut(.defaultAction)
                .disabled(!recorder.canRecord || !app.permissions.allRequiredGranted)
        }
    }

    private func refresh() async {
        app.permissions.refresh()
        await recorder.catalog.refresh()
        recorder.validateTarget()
        if recorder.settings.microphoneID != nil,
           !recorder.catalog.microphones.contains(where: { $0.id == recorder.settings.microphoneID }) {
            recorder.settings.microphoneID = nil
        }
    }
}

private struct KeyCap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys).font(Typo.mono).foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 6).frame(height: 20)
            .background(Palette.raised, in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.stroke))
    }
}

// MARK: - Sources

private struct SourcePicker: View {
    @Bindable var recorder: RecordingController

    var body: some View {
        switch recorder.sourceKind {
        case .display: DisplayGrid(recorder: recorder)
        case .window: WindowGrid(recorder: recorder)
        case .area: AreaPanel(recorder: recorder)
        case .iPhone: DeviceList(recorder: recorder)
        }
    }
}

private struct DisplayGrid: View {
    @Bindable var recorder: RecordingController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(recorder.catalog.displays) { display in
                    SourceCard(
                        image: recorder.catalog.thumbnails[CaptureSourceCatalog.thumbnailKey(display: display.id)],
                        aspect: display.frame.width / display.frame.height,
                        title: display.name,
                        subtitle: "\(Int(display.frame.width * display.scale)) × \(Int(display.frame.height * display.scale)) · \(display.maxFPS) Hz",
                        icon: nil, selected: recorder.settings.target == .display(id: display.id)
                    ) { recorder.settings.target = .display(id: display.id) }
                    .frame(width: 280)
                    .task { await recorder.catalog.loadThumbnail(display: display.id) }
                }
            }
            .padding(4)
        }
        .overlay {
            if recorder.catalog.displays.isEmpty {
                SCEmptyState(icon: "display", title: "No displays", message: "Grant Screen Recording permission to see your displays.") {}
            }
        }
    }
}

private struct WindowGrid: View {
    @Bindable var recorder: RecordingController
    @State private var query = ""

    private var windows: [WindowSource] {
        guard !query.isEmpty else { return recorder.catalog.windows }
        return recorder.catalog.windows.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            SCTextField(placeholder: "Search windows or apps", text: $query, icon: "magnifyingglass")
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 14) {
                    ForEach(windows) { window in
                        SourceCard(
                            image: recorder.catalog.thumbnails[CaptureSourceCatalog.thumbnailKey(window: window.id)],
                            aspect: 16 / 10, title: window.title, subtitle: window.appName,
                            icon: NSRunningApplication(processIdentifier: window.processID)?.icon,
                            selected: recorder.settings.target == .window(id: window.id)
                        ) { recorder.settings.target = .window(id: window.id) }
                        .task { await recorder.catalog.loadThumbnail(window: window.id) }
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.hidden)
        }
        .overlay {
            if recorder.catalog.windows.isEmpty {
                SCEmptyState(icon: "macwindow", title: "No windows", message: "Open the app you want to record, then refresh.") {}
            }
        }
    }
}

private struct AreaPanel: View {
    @Bindable var recorder: RecordingController

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.m)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: 120, height: 72)
                Image(systemName: "plus.viewfinder").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.accent)
            }
            if case let .area(id, _, _, w, h) = recorder.settings.target {
                let name = recorder.catalog.displays.first { $0.id == id }?.name ?? "display"
                VStack(spacing: 3) {
                    Text("\(Int(w)) × \(Int(h))").font(Typo.title).monospacedDigit()
                    Text("on \(name)").font(Typo.label).foregroundStyle(Palette.textSecondary)
                }
            } else {
                Text("Drag over the part of the screen you want to record").font(Typo.body).foregroundStyle(Palette.textSecondary)
            }
            Button(recorder.settings.target.isArea ? "Select Another Area" : "Select Area", systemImage: "rectangle.dashed") {
                Task {
                    let window = NSApp.keyWindow
                    window?.orderOut(nil)
                    await recorder.selectArea()
                    window?.makeKeyAndOrderFront(nil)
                }
            }
            .buttonStyle(.sc(.primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Palette.stroke))
    }
}

private struct DeviceList: View {
    @Bindable var recorder: RecordingController

    var body: some View {
        Group {
            if recorder.catalog.iOSDevices.isEmpty {
                SCEmptyState(
                    icon: "cable.connector",
                    title: "Connect your iPhone",
                    message: "Plug it in with a cable, unlock it and tap Trust.\nFor the iOS Simulator, use the Window source."
                ) {}
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(recorder.catalog.iOSDevices) { device in
                            DeviceRow(name: device.name, selected: recorder.settings.target == .iPhone(deviceID: device.id)) {
                                recorder.settings.target = .iPhone(deviceID: device.id)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: recorder.catalog.iOSDevices) { recorder.validateTarget() }
    }
}

private struct DeviceRow: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.system(size: 18)).frame(width: 36, height: 36)
                    .background(Palette.raised, in: .rect(cornerRadius: Radius.m))
                Text(name).font(Typo.bodyMedium)
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent).opacity(selected ? 1 : 0)
            }
            .padding(10)
            .background(selected ? Palette.accentSoft : hovering ? Palette.hover : Palette.surface, in: .rect(cornerRadius: Radius.l))
            .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(selected ? Palette.accent : Palette.stroke))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

private struct SourceCard: View {
    let image: CGImage?
    let aspect: Double
    let title: String
    let subtitle: String
    let icon: NSImage?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle().fill(Palette.canvas)
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Radius.m))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.m)
                        .strokeBorder(selected ? Palette.accent : hovering ? Palette.strokeStrong : Palette.stroke, lineWidth: selected ? 2.5 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(Palette.accent, in: .circle).padding(6)
                    }
                }
                HStack(spacing: 7) {
                    if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(Typo.label).foregroundStyle(Palette.text).lineLimit(1)
                        Text(subtitle).font(Typo.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

// MARK: - Audio & quality

private struct AudioSection: View {
    @Bindable var recorder: RecordingController

    var body: some View {
        HStack(spacing: 24) {
            Toggle(isOn: $recorder.settings.captureSystemAudio) {
                Label(recorder.sourceKind == .iPhone ? "Device audio" : "System audio", systemImage: "speaker.wave.2.fill")
                    .labelStyle(SCLabelStyle())
            }
            .toggleStyle(.scSwitch)
            .frame(width: 190)
            SCDivider(vertical: true).frame(height: 22)
            HStack(spacing: 10) {
                Label("Microphone", systemImage: "mic.fill").labelStyle(SCLabelStyle())
                Spacer(minLength: 0)
                SCDropdown(
                    selection: $recorder.settings.microphoneID,
                    options: [SCDropdownOption(String?.none, "None", icon: "mic.slash")]
                        + recorder.catalog.microphones.map { SCDropdownOption(Optional($0.id), $0.name, icon: "mic") },
                    minWidth: 200, fill: true
                )
                .disabled(recorder.sourceKind == .iPhone)
            }
        }
        .font(Typo.body)
    }
}

private struct QualitySection: View {
    @Bindable var recorder: RecordingController

    private var maxFPS: Int {
        if case let .display(id) = recorder.settings.target {
            return recorder.catalog.displays.first { $0.id == id }?.maxFPS ?? 60
        }
        return recorder.catalog.displays.map(\.maxFPS).max() ?? 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SCSectionHeader("Quality")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    label("Frame rate")
                    SCSegmented(selection: $recorder.settings.fps, options: fpsOptions)
                    label("Resolution")
                    SCSegmented(selection: $recorder.settings.resolutionScale, options: [
                        SCSegmentOption(1.0, "Native"), SCSegmentOption(0.5, "Half"),
                    ])
                }
                GridRow {
                    label("Format")
                    SCDropdown(selection: $recorder.settings.codec, options: [
                        SCDropdownOption(VideoCodec.hevc, "HEVC", icon: "film"),
                        SCDropdownOption(VideoCodec.h264, "H.264", icon: "film"),
                        SCDropdownOption(VideoCodec.proRes422, "ProRes 422", icon: "film.stack"),
                    ], minWidth: 150)
                    label("Countdown")
                    SCSegmented(selection: $recorder.settings.countdown, options: [
                        SCSegmentOption(0, "Off"), SCSegmentOption(3, "3s"), SCSegmentOption(5, "5s"),
                    ])
                }
            }
            HStack(spacing: 24) {
                SCSlider(
                    title: "Bitrate", value: $recorder.settings.quality, in: 0.3...1, defaultValue: 0.85,
                    format: { "\(Int($0 * 100))%" }
                )
                .disabled(recorder.settings.codec == .proRes422)
                Toggle("Hide Smooth Cursor windows", isOn: $recorder.settings.excludeOwnWindows)
                    .toggleStyle(.scSwitch)
                    .disabled(recorder.sourceKind == .window || recorder.sourceKind == .iPhone)
            }
        }
        .onChange(of: maxFPS) { if recorder.settings.fps > maxFPS { recorder.settings.fps = 60 } }
    }

    private var fpsOptions: [SCSegmentOption<Int>] {
        var options = [SCSegmentOption(30, "30"), SCSegmentOption(60, "60")]
        if maxFPS >= 120 { options.append(SCSegmentOption(120, "120")) }
        return options
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Typo.label).foregroundStyle(Palette.textSecondary)
    }
}

extension Optional where Wrapped == CaptureTarget {
    var isArea: Bool { if case .area = self { true } else { false } }
}
