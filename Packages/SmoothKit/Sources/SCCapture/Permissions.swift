import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import IOKit.hid
import Observation
@preconcurrency import ScreenCaptureKit

public enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case microphone
    case camera
    /// Needed for global mouse/keyboard event taps (clicks, keystroke overlay).
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .accessibility: "Accessibility"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording: "Required to capture your screen."
        case .microphone: "For narration."
        case .camera: "For a webcam overlay."
        case .accessibility: "Captures clicks and keystrokes for auto-zoom and the keystroke overlay."
        }
    }

    public var isRequired: Bool { self == .screenRecording }

    var settingsAnchor: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

public enum PermissionStatus: Sendable { case granted, denied, notDetermined }

@MainActor
@Observable
public final class PermissionCenter {
    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    /// True after the user was sent to System Settings for screen recording: macOS only applies
    /// the grant to a fresh process, so we offer a relaunch.
    public private(set) var screenRecordingNeedsRelaunch = false
    /// `CGPreflightScreenCaptureAccess` can disagree with what ScreenCaptureKit actually allows,
    /// so a successful content query counts as granted too.
    private var screenCaptureVerified = false
    private var verifying = false

    public init() { refresh() }

    public var allRequiredGranted: Bool {
        PermissionKind.allCases.filter(\.isRequired).allSatisfy { statuses[$0] == .granted }
    }

    public func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notDetermined }

    public func refresh() {
        for kind in PermissionKind.allCases { statuses[kind] = Self.currentStatus(kind) }
        if screenCaptureVerified { statuses[.screenRecording] = .granted }
        if statuses[.screenRecording] != .granted { verifyScreenCapture() }
    }

    /// Asks ScreenCaptureKit directly; this is the ground truth for whether capture will work.
    private func verifyScreenCapture() {
        guard !verifying else { return }
        verifying = true
        Task {
            defer { verifying = false }
            guard (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil else { return }
            screenCaptureVerified = true
            screenRecordingNeedsRelaunch = false
            statuses[.screenRecording] = .granted
        }
    }

    /// Starts a fresh instance of the app and quits this one.
    public func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    public func request(_ kind: PermissionKind) async {
        switch kind {
        case .screenRecording:
            // Shows the system prompt only the first time; afterwards the user must use System Settings.
            if !CGRequestScreenCaptureAccess() {
                openSettings(for: kind)
                screenRecordingNeedsRelaunch = true
            }
        case .microphone:
            if Self.currentStatus(kind) == .denied { openSettings(for: kind) }
            else { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        case .camera:
            if Self.currentStatus(kind) == .denied { openSettings(for: kind) }
            else { _ = await AVCaptureDevice.requestAccess(for: .video) }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(for: kind) }
        }
        refresh()
    }

    public func openSettings(for kind: PermissionKind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func currentStatus(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            return avStatus(.audio)
        case .camera:
            return avStatus(.video)
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        }
    }

    private static func avStatus(_ type: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
