import AppKit
import SwiftUI

/// Transparent, full-size title bar whose traffic lights are vertically centered in our own
/// `SCTitleBar` (which is taller than the system's 28 pt strip). Re-applied whenever AppKit
/// lays the title bar out again (resize, key change, leaving full screen).
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            window.backgroundColor = NSColor(Palette.canvas)

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutTrafficLights() }
                })
            }
            DispatchQueue.main.async { self.layoutTrafficLights() }
        }

        private func layoutTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview
            else { return }
            let height = SCTitleBar<EmptyView, EmptyView, EmptyView>.height
            var frame = container.frame
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
            titlebar.frame = container.bounds

            // AppKit's title bar glass/background grows with the container and would paint over our bar.
            let buttonViews = Set([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                window.standardWindowButton($0).map(ObjectIdentifier.init)
            })
            for view in titlebar.subviews + container.subviews where view !== titlebar && !(view is ClickForwardingView) {
                if !buttonViews.contains(ObjectIdentifier(view)) { view.isHidden = true }
            }
            // The title bar sits above our content; forward clicks that don't land on the traffic lights.
            if !titlebar.subviews.contains(where: { $0 is ClickForwardingView }), let content = window.contentView {
                let forwarder = ClickForwardingView(target: content)
                forwarder.frame = titlebar.bounds
                forwarder.autoresizingMask = [.width, .height]
                titlebar.addSubview(forwarder, positioned: .below, relativeTo: nil)
            }

            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in buttons.enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                button.setFrameOrigin(NSPoint(
                    x: 20 + CGFloat(index) * 20,
                    y: (height - button.frame.height) / 2
                ))
            }
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Sits inside the system title bar and routes hits to the window's SwiftUI content.
private final class ClickForwardingView: NSView {
    weak var target: NSView?

    init(target: NSView) {
        self.target = target
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target, let superview, let targetParent = target.superview,
              frame.contains(point) else { return nil }
        let inWindow = superview.convert(point, to: nil)
        return target.hitTest(targetParent.convert(inWindow, from: nil))
    }
}
