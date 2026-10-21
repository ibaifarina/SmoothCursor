import AppKit
import SwiftUI

/// Floating control pill + menu bar item shown while recording. Both are excluded from the capture.
final class RecordingHUD {
    private unowned let controller: RecordingController
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    init(controller: RecordingController) {
        self.controller = controller
    }

    var windowIDs: [CGWindowID] {
        panel.map { [CGWindowID($0.windowNumber)] } ?? []
    }

    func show(on screen: NSScreen?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28))
        panel.orderFrontRegardless()

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageLeading
            item.menu = makeMenu()
            statusItem = item
        }
        updateStatusItem()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none
        let host = NSHostingView(rootView: HUDView(controller: controller))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        return panel
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let paused = controller.phase == .paused
        button.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill", accessibilityDescription: nil)
        button.contentTintColor = paused ? .systemOrange : .systemRed
        button.title = " " + controller.elapsed.clock
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Stop Recording", key: "r", modifiers: [.command, .option, .shift]) { [weak controller] in controller?.stop() })
        menu.addItem(menuItem("Pause / Resume", key: "p", modifiers: [.command, .option, .shift]) { [weak controller] in controller?.togglePause() })
        menu.addItem(menuItem("Restart") { [weak controller] in controller?.restart() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Cancel Recording") { [weak controller] in controller?.cancel() })
        return menu
    }
}

private struct HUDView: View {
    let controller: RecordingController

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(controller.phase == .paused ? Palette.warning : Palette.record)
                .frame(width: 10, height: 10)
                .opacity(controller.phase == .recording ? 1 : 0.6)
            Text(statusText)
                .font(.system(.body, design: .rounded).monospacedDigit().weight(.medium))
                .frame(width: 72, alignment: .leading)
            Spacer(minLength: 0)
            HUDButton(symbol: controller.phase == .paused ? "play.fill" : "pause.fill", help: "Pause / Resume (⌥⇧⌘P)") {
                controller.togglePause()
            }
            .disabled(!(controller.phase == .recording || controller.phase == .paused))
            HUDButton(symbol: "arrow.counterclockwise", help: "Restart") { controller.restart() }
            HUDButton(symbol: "trash", help: "Cancel") { controller.cancel() }
            Button(action: controller.stop) {
                RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 11, height: 11)
                    .frame(width: 30, height: 30)
                    .background(Palette.record, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Stop (⌥⇧⌘R)")
        }
        .padding(.horizontal, 16)
        .frame(width: 300, height: 52)
        .background(Palette.surface.opacity(0.92), in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.strokeStrong))
        .foregroundStyle(Palette.text)
        .environment(\.colorScheme, .dark)
    }

    private var statusText: String {
        switch controller.phase {
        case let .countdown(n): "Starting \(n)"
        case .finishing: "Saving…"
        default: controller.elapsed.clock
        }
    }
}

private struct HUDButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 26).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Menu item that runs a closure; the target is retained via `representedObject`.
func menuItem(
    _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], handler: @escaping () -> Void
) -> NSMenuItem {
    let target = MenuTarget(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuTarget.fire), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = target
    item.representedObject = target
    return item
}

private final class MenuTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

extension Double {
    /// "m:ss" recording clock.
    var clock: String {
        let total = Int(max(0, self))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
