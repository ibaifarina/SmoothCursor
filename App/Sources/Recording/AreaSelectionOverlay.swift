import AppKit

/// Full-screen drag-to-select overlay on every display. Hold Shift to lock 16:9. Esc cancels.
enum AreaSelectionOverlay {
    /// Returns the display and the selected rect in that display's points (origin top-left).
    static func select() async -> (CGDirectDisplayID, CGRect)? {
        await withCheckedContinuation { continuation in
            let session = Session { continuation.resume(returning: $0) }
            session.begin()
        }
    }

    private final class Session {
        private var windows: [NSWindow] = []
        private var completion: (((CGDirectDisplayID, CGRect)?) -> Void)?
        private var keepAlive: Session?

        init(completion: @escaping ((CGDirectDisplayID, CGRect)?) -> Void) {
            self.completion = completion
        }

        func begin() {
            keepAlive = self
            for screen in NSScreen.screens {
                let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.level = .screenSaver
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.sharingType = .none
                let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.onFinish = { [weak self] rect in self?.finish(screen: screen, rect: rect) }
                window.contentView = view
                window.setFrame(screen.frame, display: true)
                window.makeKeyAndOrderFront(nil)
                windows.append(window)
            }
            NSApp.activate()
            NSCursor.crosshair.push()
        }

        private func finish(screen: NSScreen, rect: CGRect?) {
            NSCursor.pop()
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            if let rect, let id {
                // View coordinates are bottom-left; capture wants top-left.
                let flipped = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
                completion?((id, flipped.integral))
            } else {
                completion?(nil)
            }
            completion = nil
            keepAlive = nil
        }
    }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var onFinish: ((CGRect?) -> Void)?
        private var start: CGPoint?
        private var current: CGPoint?
        private var shiftLocked = false

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var selection: CGRect? {
            guard let start, let current else { return nil }
            var w = current.x - start.x, h = current.y - start.y
            if shiftLocked {
                let height = abs(w) * 9 / 16
                h = h < 0 ? -height : height
            }
            w = abs(w); h = abs(h)
            let x = current.x < start.x ? start.x - w : start.x
            let y = current.y < start.y ? start.y - h : start.y
            return CGRect(x: x, y: y, width: w, height: h)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            start = convert(event.locationInWindow, from: nil)
            current = start
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            shiftLocked = event.modifierFlags.contains(.shift)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            guard let rect = selection, rect.width >= 40, rect.height >= 40 else {
                start = nil; current = nil; needsDisplay = true
                return
            }
            onFinish?(rect)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds)
            if let rect = selection {
                path.append(NSBezierPath(rect: rect))
                path.windingRule = .evenOdd
            }
            NSColor.black.withAlphaComponent(0.35).setFill()
            path.fill()

            guard let rect = selection else {
                drawLabel("Drag to select an area · Shift for 16:9 · Esc to cancel", at: CGPoint(x: bounds.midX, y: bounds.midY))
                return
            }
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            drawLabel("\(Int(rect.width)) × \(Int(rect.height))", at: CGPoint(x: rect.midX, y: rect.minY - 22))
        }

        private func drawLabel(_ text: String, at center: CGPoint) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let size = string.size()
            let box = CGRect(x: center.x - size.width / 2 - 10, y: center.y - size.height / 2 - 5, width: size.width + 20, height: size.height + 10)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            string.draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5))
        }
    }
}
