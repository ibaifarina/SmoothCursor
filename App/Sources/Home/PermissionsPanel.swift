import SCCapture
import SwiftUI

struct PermissionsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SCPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(Palette.accent)
                    Text("A few permissions before you record").font(Typo.bodyMedium)
                }
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, status: app.permissions.status(kind)) {
                        Task { await app.permissions.request(kind) }
                    }
                }
            }
        }
    }
}

struct PermissionRow: View {
    @Environment(AppModel.self) private var app
    let kind: PermissionKind
    let status: PermissionStatus
    let request: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status == .granted ? "checkmark" : symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status == .granted ? Palette.success : Palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(status == .granted ? Palette.success.opacity(0.14) : Palette.raised, in: .rect(cornerRadius: Radius.m))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(kind.title).font(Typo.bodyMedium)
                    if !kind.isRequired { SCBadge(text: "Optional") }
                }
                Text(kind.purpose).font(Typo.label).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if status != .granted {
                if kind == .screenRecording && app.permissions.screenRecordingNeedsRelaunch {
                    Button("Relaunch") { app.permissions.relaunch() }
                        .buttonStyle(.sc(.ghost, size: .small))
                        .help("macOS applies the Screen Recording permission after the app restarts.")
                }
                Button(status == .denied ? "Open Settings" : "Allow", action: request)
                    .buttonStyle(.sc(kind.isRequired ? .primary : .secondary, size: .small))
            } else {
                Text("Granted").font(Typo.label).foregroundStyle(Palette.success)
            }
        }
    }

    private var symbol: String {
        switch kind {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic"
        case .camera: "video"
        case .accessibility: "keyboard"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(Typo.largeTitle).padding(.top, 8)
            SCSectionHeader("Permissions")
            SCPanel {
                VStack(spacing: 12) {
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionRow(kind: kind, status: app.permissions.status(kind)) {
                            Task { await app.permissions.request(kind) }
                        }
                    }
                }
            }
            SCSectionHeader("Library")
            SCPanel {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Projects folder").font(Typo.bodyMedium)
                        Text(app.library.rootURL.path(percentEncoded: false))
                            .font(Typo.label).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(app.library.rootURL) }
                        .buttonStyle(.sc(.secondary, size: .small))
                }
            }
            SCSectionHeader("Shortcuts")
            SCPanel {
                VStack(spacing: 8) {
                    shortcut("Start / stop recording", "⌥⇧⌘R")
                    shortcut("Pause / resume", "⌥⇧⌘P")
                    shortcut("New recording", "⌘N")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 560)
        .onAppear { app.permissions.refresh() }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title).font(Typo.body)
            Spacer()
            Text(keys).font(Typo.mono).foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Palette.raised, in: .rect(cornerRadius: Radius.s))
        }
    }
}
