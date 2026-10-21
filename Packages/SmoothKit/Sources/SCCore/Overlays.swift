import CoreGraphics
import Foundation

/// Text drawn on top of the frame (keystrokes, captions), in output pixels.
public struct OverlayText: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// Rounded pill; dark or light.
        case keys(light: Bool)
        /// Caption text, on a box or bare with a shadow.
        case caption(boxed: Bool)
    }
    public var text: String
    public var fontSize: Double
    public var style: Style
    /// Wrap width (captions).
    public var maxWidth: Double
}

public struct Overlay: Equatable, Sendable {
    public var text: OverlayText
    /// Anchor point: bottom-center for bottom overlays, top-center for top ones.
    public var anchor: CGPoint
    public var anchoredAtBottom: Bool
    public var opacity: Double
    /// Small rise while appearing, in output pixels.
    public var offsetY: Double
}

/// Shortcut and typing pills, precomputed from telemetry.
public struct KeystrokeTrack: Sendable {
    public struct Badge: Sendable, Equatable {
        public var range: TimeRange
        public var text: String
    }

    public let badges: [Badge]

    public init(telemetry: Telemetry, settings: KeystrokeSettings) {
        var badges: [Badge] = []
        var typing: (start: Seconds, last: Seconds, text: String)?

        func flushTyping() {
            if let t = typing, !t.text.isEmpty {
                badges.append(Badge(range: TimeRange(start: t.start, end: t.last + 1.0), text: String(t.text.suffix(28))))
            }
            typing = nil
        }

        for e in telemetry.events where e.kind == .keyDown {
            let mods = Self.modifierSymbols(e.modifiers)
            let named = Self.namedKeys[e.code]
            let character = Self.character(e)
            let isShortcut = e.modifiers & (0x100000 | 0x40000 | 0x80000) != 0 // ⌘ ⌃ ⌥
            if isShortcut || named != nil {
                flushTyping()
                let key = named ?? character?.uppercased() ?? "?"
                let text = (mods + [key]).joined(separator: " ")
                // Repeats of the same key extend the badge instead of stacking new ones.
                if let last = badges.last, last.text == text, e.time - last.range.end < 0.3 {
                    badges[badges.count - 1].range.end = e.time + 1.2
                } else {
                    badges.append(Badge(range: TimeRange(start: e.time, end: e.time + 1.4), text: text))
                }
            } else if settings.showTyping, let character {
                if let t = typing, e.time - t.last < 1.2 {
                    typing = (t.start, e.time, t.text + character)
                } else {
                    flushTyping()
                    typing = (e.time, e.time, character)
                }
            }
        }
        flushTyping()
        // A new badge replaces the previous one.
        for i in badges.indices.dropLast() where badges[i].range.end > badges[i + 1].range.start {
            badges[i].range.end = badges[i + 1].range.start
        }
        self.badges = badges
    }

    /// Badge and fade (0...1) at `time`.
    public func badge(at time: Seconds) -> (badge: Badge, opacity: Double)? {
        guard let b = badges.last(where: { $0.range.start <= time && time < $0.range.end }) else { return nil }
        let fadeIn = min((time - b.range.start) / 0.12, 1), fadeOut = min((b.range.end - time) / 0.2, 1)
        return (b, max(min(fadeIn, fadeOut), 0))
    }

    static func modifierSymbols(_ flags: UInt32) -> [String] {
        var s: [String] = []
        if flags & 0x40000 != 0 { s.append("⌃") }
        if flags & 0x80000 != 0 { s.append("⌥") }
        if flags & 0x20000 != 0 { s.append("⇧") }
        if flags & 0x100000 != 0 { s.append("⌘") }
        return s
    }

    static let namedKeys: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The typed character: recorded with the event (any layout), or a US layout fallback for older recordings.
    static func character(_ e: Telemetry.Event) -> String? {
        if e.y > 0, let scalar = Unicode.Scalar(UInt32(e.y)), scalar.properties.isAlphabetic || scalar.properties.generalCategory != .control {
            return String(Character(scalar))
        }
        return usLayout[e.code]
    }

    static let usLayout: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`",
    ]
}

extension FrameLayout {
    /// Keystroke and caption overlays for `time`.
    static func overlays(project: Project, time: Seconds, outputSize: CGSize, keystrokes: KeystrokeTrack?) -> [Overlay] {
        let ref = referenceScale(for: outputSize)
        let margin = 0.065 * outputSize.height
        var result: [Overlay] = []
        var bottomStack = 0.0, topStack = 0.0

        if project.keystrokes.enabled, let keystrokes, let (badge, opacity) = keystrokes.badge(at: time), opacity > 0.001 {
            let size = 34 * ref * project.keystrokes.size
            let bottom = project.keystrokes.position == .bottom
            result.append(Overlay(
                text: OverlayText(text: badge.text, fontSize: size, style: .keys(light: project.keystrokes.lightStyle), maxWidth: outputSize.width * 0.8),
                anchor: CGPoint(x: outputSize.width / 2, y: bottom ? outputSize.height - margin : margin),
                anchoredAtBottom: bottom, opacity: opacity, offsetY: (1 - opacity) * 8 * ref
            ))
            if bottom { bottomStack += size * 2.2 } else { topStack += size * 2.2 }
        }

        if project.captions.enabled, let caption = project.captionSegments.first(where: { $0.range.contains(time) }) {
            let fadeIn = min((time - caption.range.start) / 0.1, 1), fadeOut = min((caption.range.end - time) / 0.1, 1)
            let size = 38 * ref * project.captions.size
            let bottom = project.captions.position == .bottom
            let y = bottom ? outputSize.height - margin - bottomStack : margin + topStack
            result.append(Overlay(
                text: OverlayText(text: caption.text, fontSize: size, style: .caption(boxed: project.captions.boxed), maxWidth: outputSize.width * 0.78),
                anchor: CGPoint(x: outputSize.width / 2, y: y),
                anchoredAtBottom: bottom, opacity: max(min(fadeIn, fadeOut), 0), offsetY: 0
            ))
        }
        return result
    }
}
