import SCProject
import SwiftUI

@main
struct SmoothCursorApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("Smooth Cursor", id: WindowID.home) {
            HomeView()
                .environment(app)
                .frame(minWidth: 820, minHeight: 560)
                .appWindowStyle()
        }
        .defaultSize(width: 1080, height: 720)
        .commands { AppCommands(app: app) }

        Window("New Recording", id: WindowID.recorder) {
            RecorderView()
                .environment(app)
                .appWindowStyle()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        WindowGroup(id: WindowID.editor, for: URL.self) { $packageURL in
            if let packageURL {
                EditorWindow(packageURL: packageURL)
                    .environment(app)
                    .frame(minWidth: 1100, minHeight: 700)
                    .appWindowStyle()
            }
        }
        .defaultSize(width: 1440, height: 900)

        Settings {
            SettingsView()
                .environment(app)
                .appWindowStyle()
        }
    }
}

enum WindowID {
    static let home = "home"
    static let editor = "editor"
    static let recorder = "recorder"
}

struct AppCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording…") { openWindow(id: WindowID.recorder) }
                .keyboardShortcut("n")
            Button(app.recorder.phase == .idle ? "Start Recording" : "Stop Recording") {
                app.recorder.phase == .idle ? app.recorder.start() : app.recorder.stop()
            }
            .disabled(app.recorder.phase == .idle && !app.recorder.canRecord)
            Divider()
            Button("Open Project…") {
                if let url = app.chooseProjectFile() { openWindow(id: WindowID.editor, value: url) }
            }
            .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.library.projects.prefix(10)) { project in
                    Button(project.name) { openWindow(id: WindowID.editor, value: project.url) }
                }
            }
            .disabled(app.library.projects.isEmpty)
            Divider()
            Button("Projects") { openWindow(id: WindowID.home) }
                .keyboardShortcut("0")
        }
    }
}
