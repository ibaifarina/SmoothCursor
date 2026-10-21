import AppKit
@preconcurrency import AVFoundation
import Observation
import SCCore
@preconcurrency import ScreenCaptureKit

public struct DisplaySource: Identifiable, Hashable, Sendable {
    public var id: CGDirectDisplayID
    public var name: String
    /// Global frame in points, origin top-left.
    public var frame: CGRect
    public var scale: Double
    public var maxFPS: Int
}

public struct WindowSource: Identifiable, Hashable, Sendable {
    public var id: CGWindowID
    public var title: String
    public var appName: String
    public var bundleID: String?
    public var processID: pid_t
    public var frame: CGRect
}

public struct InputDeviceSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
}

/// Everything that can be recorded right now, plus picker thumbnails.
@MainActor
@Observable
public final class CaptureSourceCatalog {
    public private(set) var displays: [DisplaySource] = []
    public private(set) var windows: [WindowSource] = []
    public private(set) var microphones: [InputDeviceSource] = []
    public private(set) var iOSDevices: [InputDeviceSource] = []
    public private(set) var thumbnails: [String: CGImage] = [:]
    public private(set) var lastError: String?

    @ObservationIgnored private var content: SCShareableContent?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {
        DeviceCaptureEngine.enableScreenCaptureDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
        refreshDevices()
    }

    public var defaultMicrophoneID: String? { AVCaptureDevice.default(for: .audio)?.uniqueID }

    public func refresh() async {
        refreshDevices()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            self.content = content
            displays = content.displays.map(Self.describe)
            let me = getpid()
            windows = content.windows
                .filter { w in
                    w.windowLayer == 0 && w.frame.width >= 120 && w.frame.height >= 80
                        && w.owningApplication?.processID != me
                        && !(w.title ?? "").isEmpty
                }
                .map { w in
                    WindowSource(
                        id: w.windowID, title: w.title ?? "", appName: w.owningApplication?.applicationName ?? "",
                        bundleID: w.owningApplication?.bundleIdentifier, processID: w.owningApplication?.processID ?? 0,
                        frame: w.frame
                    )
                }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshDevices() {
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { InputDeviceSource(id: $0.uniqueID, name: $0.localizedName) }
        iOSDevices = DeviceCaptureEngine.availableDevices().map { InputDeviceSource(id: $0.uniqueID, name: $0.localizedName) }
    }

    public static func thumbnailKey(display id: CGDirectDisplayID) -> String { "d\(id)" }
    public static func thumbnailKey(window id: CGWindowID) -> String { "w\(id)" }

    /// Loads (once) a small preview image for a display or window.
    public func loadThumbnail(display id: CGDirectDisplayID) async {
        guard let display = content?.displays.first(where: { $0.displayID == id }) else { return }
        let me = content?.applications.filter { $0.processID == getpid() } ?? []
        await loadThumbnail(
            key: Self.thumbnailKey(display: id),
            filter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
            size: display.frame.size
        )
    }

    public func loadThumbnail(window id: CGWindowID) async {
        guard let window = content?.windows.first(where: { $0.windowID == id }) else { return }
        await loadThumbnail(key: Self.thumbnailKey(window: id), filter: SCContentFilter(desktopIndependentWindow: window), size: window.frame.size)
    }

    private func loadThumbnail(key: String, filter: SCContentFilter, size: CGSize) async {
        guard thumbnails[key] == nil, size.width > 0, size.height > 0 else { return }
        let config = SCStreamConfiguration()
        let width = 480.0
        config.width = Int(width)
        config.height = Int(width * size.height / size.width)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
            thumbnails[key] = image
        }
    }

    private static func describe(_ display: SCDisplay) -> DisplaySource {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
        return DisplaySource(
            id: display.displayID,
            name: screen?.localizedName ?? "Display \(display.displayID)",
            frame: CGDisplayBounds(display.displayID),
            scale: Double(screen?.backingScaleFactor ?? 2),
            maxFPS: screen?.maximumFramesPerSecond ?? 60
        )
    }
}
