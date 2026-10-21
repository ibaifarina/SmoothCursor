import AppKit
import SwiftUI

/// Big centered countdown number before capture starts. Click-through, never captured.
final class CountdownOverlay {
    private var panel: NSPanel?
    private let model = CountdownModel()

    func show(_ value: Int, on screen: NSScreen?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let frame = (screen ?? NSScreen.main)?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        model.value = value
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 220),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        return panel
    }
}

@Observable
private final class CountdownModel {
    var value = 3
}

private struct CountdownView: View {
    let model: CountdownModel

    var body: some View {
        Text("\(model.value)")
            .font(.system(size: 96, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .contentTransition(.numericText(countsDown: true))
            .frame(width: 180, height: 180)
            .background(.ultraThinMaterial, in: .circle)
            .environment(\.colorScheme, .dark)
            .animation(.spring(duration: 0.35), value: model.value)
            .frame(width: 220, height: 220)
    }
}
