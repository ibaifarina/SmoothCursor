import AppKit
import Observation
import SCCapture
import SCCore
import SCProject

enum RecordingPhase: Equatable {
    case idle
    case selectingArea
    case countdown(Int)
    case recording
    case paused
    case finishing

    var isActive: Bool { self != .idle && self != .selectingArea }
}

enum SourceKind: String, CaseIterable, Identifiable {
    case display, window, area, iPhone
    var id: String { rawValue }
    var title: String { self == .iPhone ? "iPhone" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        case .iPhone: "iphone"
        }
    }
}

/// Drives a recording from source picking to a finished project.
@Observable
final class RecordingController {
    let catalog = CaptureSourceCatalog()
    var settings: RecordingSettings { didSet { persistSettings() } }
    var sourceKind: SourceKind = .display
    private(set) var phase: RecordingPhase = .idle
    private(set) var elapsed: Seconds = 0
    var errorMessage: String?

    /// Set by any SwiftUI window so we can open editors / the recorder from AppKit callbacks.
    @ObservationIgnored var openEditor: ((URL) -> Void)?
    @ObservationIgnored var openRecorder: (() -> Void)?

    @ObservationIgnored private let library: ProjectLibrary
    @ObservationIgnored private var engine: (any RecordingEngine)?
    @ObservationIgnored private var packageURL: URL?
    @ObservationIgnored private var projectName = ""
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private lazy var hud = RecordingHUD(controller: self)
    @ObservationIgnored private lazy var countdownOverlay = CountdownOverlay()
    @ObservationIgnored private var hotKeys: GlobalHotKeys?

    private static let settingsKey = "recordingSettings"

    init(library: ProjectLibrary) {
        self.library = library
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(RecordingSettings.self, from: data) {
            settings = saved
        } else {
            settings = RecordingSettings()
        }
        sourceKind = switch settings.target {
        case .window: .window
        case .area: .area
        case .iPhone: .iPhone
        default: .display
        }
        hotKeys = GlobalHotKeys { [weak self] action in self?.handleHotKey(action) }
    }

    // MARK: Source selection

    func validateTarget() {
        switch settings.target {
        case let .display(id) where catalog.displays.contains { $0.id == id }: return
        case let .window(id) where catalog.windows.contains { $0.id == id }: return
        case let .area(id, _, _, _, _) where catalog.displays.contains { $0.id == id }: return
        case let .iPhone(id) where catalog.iOSDevices.contains { $0.id == id }: return
        default: break
        }
        switch sourceKind {
        case .display: settings.target = catalog.displays.first.map { .display(id: $0.id) }
        case .iPhone: settings.target = catalog.iOSDevices.first.map { .iPhone(deviceID: $0.id) }
        case .window, .area: settings.target = nil
        }
    }

    var canRecord: Bool {
        guard phase == .idle, let target = settings.target else { return false }
        return switch (sourceKind, target) {
        case (.display, .display), (.window, .window), (.area, .area), (.iPhone, .iPhone): true
        default: false
        }
    }

    func selectArea() async {
        phase = .selectingArea
        defer { phase = .idle }
        if let (display, rect) = await AreaSelectionOverlay.select() {
            settings.target = .area(displayID: display, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard canRecord else { return }
        errorMessage = nil
        projectName = "Recording " + Date.now.formatted(.dateTime.year().month().day().hour().minute())
        do {
            packageURL = try library.makePackage(name: projectName)
        } catch {
            fail(error)
            return
        }
        hud.show(on: targetScreen)
        runCountdownThenCapture()
    }

    func stop() {
        guard phase == .recording || phase == .paused || phase.isCountdown else { return }
        if phase.isCountdown { cancel(); return }
        phase = .finishing
        stopTicker()
        Task {
            do {
                guard let engine, let packageURL else { return }
                let result = try await engine.stop()
                try library.finalizeProject(at: packageURL, name: projectName, recording: result.recording)
                finish()
                NSApp.activate()
                openEditor?(packageURL)
            } catch {
                fail(error)
            }
        }
    }

    func togglePause() {
        guard let engine else { return }
        if phase == .recording {
            engine.pause()
            phase = .paused
        } else if phase == .paused {
            engine.resume()
            phase = .recording
        }
    }

    /// Throws away what was captured so far and starts over (with countdown).
    func restart() {
        guard phase.isActive, phase != .finishing else { return }
        countdownTask?.cancel()
        stopTicker()
        let engine = self.engine
        self.engine = nil
        Task {
            await engine?.cancel()
            runCountdownThenCapture()
        }
    }

    func cancel() {
        countdownTask?.cancel()
        countdownOverlay.hide()
        stopTicker()
        let engine = self.engine, url = packageURL
        Task {
            await engine?.cancel()
            if let url { library.discardPackage(url) }
            finish()
        }
    }

    private func runCountdownThenCapture() {
        countdownTask = Task {
            for n in stride(from: settings.countdown, to: 0, by: -1) {
                phase = .countdown(n)
                countdownOverlay.show(n, on: targetScreen)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdownOverlay.hide()
            await beginCapture()
        }
    }

    private func beginCapture() async {
        guard let packageURL else { return }
        let engine: any RecordingEngine
        if case .iPhone = settings.target {
            engine = DeviceCaptureEngine()
        } else {
            let screen = ScreenCaptureEngine()
            screen.excludedWindowIDs = hud.windowIDs
            engine = screen
        }
        engine.onFailure = { [weak self] error in
            Task { @MainActor in self?.fail(error) }
        }
        self.engine = engine
        do {
            try await engine.start(settings: settings, packageURL: packageURL)
            phase = .recording
            elapsed = 0
            startTicker()
        } catch {
            fail(error)
        }
    }

    private func finish() {
        engine = nil
        packageURL = nil
        phase = .idle
        hud.hide()
        countdownOverlay.hide()
    }

    private func fail(_ error: Error) {
        guard phase != .idle || engine != nil || packageURL != nil else { return }
        errorMessage = error.localizedDescription
        let engine = self.engine, url = packageURL
        self.engine = nil
        stopTicker()
        Task {
            await engine?.cancel()
            if let url { library.discardPackage(url) }
            finish()
            NSApp.activate()
            openRecorder?()
        }
    }

    // MARK: Helpers

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                self.elapsed = engine.clock.elapsed.seconds
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Screen the countdown and HUD appear on.
    var targetScreen: NSScreen? {
        let displayID: CGDirectDisplayID? = switch settings.target {
        case let .display(id): id
        case let .area(id, _, _, _, _): id
        case let .window(id): catalog.windows.first { $0.id == id }.flatMap { w in
            catalog.displays.first { $0.frame.intersects(w.frame) }?.id
        }
        default: nil
        }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
    }

    private func handleHotKey(_ action: GlobalHotKeys.Action) {
        switch action {
        case .toggleRecording:
            if phase == .idle {
                if canRecord { start() } else { NSApp.activate(); openRecorder?() }
            } else {
                stop()
            }
        case .togglePause:
            togglePause()
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }
}

extension RecordingPhase {
    var isCountdown: Bool { if case .countdown = self { true } else { false } }
}
