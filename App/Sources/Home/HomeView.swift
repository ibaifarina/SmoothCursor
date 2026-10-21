import SCCapture
import SCProject
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable {
    case recent, name, duration
    var title: String {
        switch self {
        case .recent: "Last edited"
        case .name: "Name"
        case .duration: "Duration"
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var query = ""
    @State private var sort: LibrarySort = .recent
    @State private var renaming: UUID?

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 20)]

    private var projects: [ProjectSummary] {
        let filtered = query.isEmpty ? app.library.projects : app.library.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return switch sort {
        case .recent: filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name: filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .duration: filtered.sorted { $0.duration > $1.duration }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            SCDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !app.permissions.allRequiredGranted { PermissionsPanel() }
                    ForEach(app.library.recoverable, id: \.self) { RecoveryBanner(url: $0) }
                    header
                    if app.library.projects.isEmpty {
                        emptyState.frame(minHeight: 380)
                    } else if projects.isEmpty {
                        SCEmptyState(icon: "magnifyingglass", title: "No matches", message: "No project matches “\(query)”.") {}
                            .frame(minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(projects) { summary in
                                ProjectCard(
                                    summary: summary,
                                    isRenaming: renaming == summary.id,
                                    onOpen: { open(summary.url) },
                                    onRename: { renaming = summary.id },
                                    onCommitRename: { name in
                                        renaming = nil
                                        app.rename(summary, to: name)
                                    }
                                )
                                .contextMenu { contextMenu(summary) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
        .overlay { if isDropTargeted { dropOverlay } }
        .dropDestination(for: URL.self) { urls, _ in
            Task { for url in urls { await importAndOpen(url) } }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.movie], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { Task { await importAndOpen(url) } }
        }
        .onAppear {
            app.recorder.openEditor = { openWindow(id: WindowID.editor, value: $0) }
            app.recorder.openRecorder = { openWindow(id: WindowID.recorder) }
            // Don't start with the search field focused.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--open-recorder") { openWindow(id: WindowID.recorder) }
            #endif
        }
        .onOpenURL { url in
            if url.pathExtension == ProjectPackage.fileExtension { open(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.permissions.refresh()
            app.library.reload()
        }
        .alert("Something went wrong", isPresented: .init(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("OK") {}
        } message: { Text(app.lastError ?? "") }
    }

    // MARK: Pieces

    private var titleBar: some View {
        SCTitleBar {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(LinearGradient(colors: [Palette.accent, Color(hex: 0xFF3D6E)], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 7))
                Text("Smooth Cursor").font(Typo.title)
            }
        } trailing: {
            SCTextField(placeholder: "Search projects", text: $query, icon: "magnifyingglass")
                .frame(width: 220)
            Button("Open", systemImage: "folder") {
                if let url = app.chooseProjectFile() { open(url) }
            }
            .buttonStyle(.sc(.ghost))
            .help("Open a project file (⌘O)")
            Button("Import", systemImage: "square.and.arrow.down") { isImporting = true }
                .buttonStyle(.sc(.secondary))
                .help("Make a project from a video file")
            Button("New Recording", systemImage: "record.circle") { openWindow(id: WindowID.recorder) }
                .buttonStyle(.sc(.record))
                .help("New Recording (⌘N)")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Projects").font(Typo.largeTitle)
            Text("\(app.library.projects.count)").font(Typo.title).foregroundStyle(Palette.textTertiary)
            Spacer()
            if !app.library.projects.isEmpty {
                SCDropdown(
                    selection: $sort,
                    options: LibrarySort.allCases.map { SCDropdownOption($0, $0.title) },
                    icon: "arrow.up.arrow.down", minWidth: 140
                )
            }
        }
    }

    private var emptyState: some View {
        SCEmptyState(
            icon: "cursorarrow.motionlines",
            title: "No projects yet",
            message: "Record your screen, or drop a video anywhere in this window."
        ) {
            Button("New Recording", systemImage: "record.circle") { openWindow(id: WindowID.recorder) }
                .buttonStyle(.sc(.record, size: .large))
            Button("Import Video") { isImporting = true }
                .buttonStyle(.sc(.secondary, size: .large))
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: Radius.xl)
            .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Palette.accent.opacity(0.06), in: .rect(cornerRadius: Radius.xl))
            .overlay {
                Label("Drop to create a project", systemImage: "square.and.arrow.down")
                    .font(Typo.title)
                    .labelStyle(SCLabelStyle())
            }
            .padding(14)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func contextMenu(_ summary: ProjectSummary) -> some View {
        Button("Open") { open(summary.url) }
        Button("Rename") { renaming = summary.id }
        Button("Duplicate") { app.duplicate(summary) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([summary.url]) }
        Divider()
        Button("Move to Trash", role: .destructive) { app.trash(summary) }
    }

    private func open(_ url: URL) {
        openWindow(id: WindowID.editor, value: url)
    }

    private func importAndOpen(_ url: URL) async {
        if let package = await app.importVideo(url) { open(package) }
    }
}

private struct RecoveryBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    let url: URL
    @State private var working = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bandage")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.warning)
                .frame(width: 32, height: 32)
                .background(Palette.warning.opacity(0.14), in: .rect(cornerRadius: Radius.m))
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfinished recording found").font(Typo.bodyMedium)
                Text("“\(url.deletingPathExtension().lastPathComponent)” was interrupted. The video can be recovered; cursor data can't.")
                    .font(Typo.label).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button("Discard") { try? app.library.discardRecoverable(url) }
                .buttonStyle(.sc(.ghost))
            Button(working ? "Recovering…" : "Recover") {
                working = true
                Task {
                    if let project = await app.recover(url) { openWindow(id: WindowID.editor, value: project) }
                    working = false
                }
            }
            .buttonStyle(.sc(.primary))
            .disabled(working)
        }
        .padding(12)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Palette.warning.opacity(0.3)))
    }
}
