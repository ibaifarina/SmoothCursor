import AppKit
import CoreGraphics
import CoreMedia
import SCCore
import Synchronization

/// Records cursor position (120 Hz), clicks, scrolls, keys and cursor sprites while capturing.
///
/// - Position: polled from `CGEvent(source:)`, no permission needed.
/// - Clicks/keys: listen-only event tap (needs Accessibility / Input Monitoring). Without it,
///   falls back to an `NSEvent` global monitor for mouse buttons and scrolls only.
/// - Sprites: the system cursor image is fingerprinted at 15 Hz; each new look is saved as a PNG.
final class InputTelemetryRecorder: @unchecked Sendable {
    enum Target {
        /// Fixed rect in global display points, origin top-left.
        case rect(CGRect)
        /// A window that may move; tracked via the window server.
        case window(CGWindowID, initial: CGRect)
    }

    private struct State {
        var events: [Telemetry.Event] = []
        var sprites: [Telemetry.CursorSprite] = []
        var spriteIndexByFingerprint: [Int: UInt16] = [:]
        var currentSprite: UInt16 = 0
        var lastPosition = CGPoint(x: -.infinity, y: -.infinity)
        var lastSpriteWritten: UInt16 = .max
        var origin: CGPoint
    }

    private let clock: RecordingClock
    private let target: Target
    private let targetSize: CGSize
    private let displayScale: Double
    private let packageURL: URL
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "smoothcursor.telemetry", qos: .userInteractive)
    private var positionTimer: DispatchSourceTimer?
    private var spriteTimer: DispatchSourceTimer?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var fallbackMonitor: Any?
    private var tick = 0

    private(set) var capturesKeys = false

    init(clock: RecordingClock, target: Target, targetSize: CGSize, displayScale: Double, packageURL: URL) {
        self.clock = clock
        self.target = target
        self.targetSize = targetSize
        self.displayScale = displayScale
        self.packageURL = packageURL
        let origin: CGPoint = switch target {
        case let .rect(r): r.origin
        case let .window(_, initial): initial.origin
        }
        state = Mutex(State(origin: origin))
    }

    func start() {
        try? FileManager.default.createDirectory(
            at: packageURL.appending(path: PackagePaths.cursors), withIntermediateDirectories: true
        )
        DispatchQueue.main.async { self.startSpriteSampling() }
        startEventTap()

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 120), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.samplePosition() }
        timer.resume()
        positionTimer = timer
    }

    func stop() -> Telemetry {
        positionTimer?.cancel()
        positionTimer = nil
        if let runLoop = tapRunLoop { CFRunLoopStop(runLoop) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        let monitor = fallbackMonitor
        let spriteTimer = spriteTimer
        DispatchQueue.main.async {
            spriteTimer?.cancel()
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        return state.withLock { s in
            Telemetry(
                header: .init(
                    targetSize: PixelSize(width: Int(targetSize.width.rounded()), height: Int(targetSize.height.rounded())),
                    displayScale: displayScale,
                    cursorSprites: s.sprites
                ),
                events: s.events.sorted { $0.time < $1.time }
            )
        }
    }

    // MARK: Position

    private func samplePosition() {
        tick += 1
        if case let .window(id, _) = target, tick % 12 == 0, let frame = Self.windowFrame(id) {
            state.withLock { $0.origin = frame.origin }
        }
        guard let time = clock.mediaTime(forHost: clock.now), let location = CGEvent(source: nil)?.location else { return }
        state.withLock { s in
            let p = CGPoint(x: location.x - s.origin.x, y: location.y - s.origin.y)
            guard p != s.lastPosition || s.currentSprite != s.lastSpriteWritten else { return }
            s.lastPosition = p
            s.lastSpriteWritten = s.currentSprite
            s.events.append(.init(time: time.seconds, kind: .move, x: Float(p.x), y: Float(p.y), code: s.currentSprite))
        }
    }

    private func record(_ kind: Telemetry.Kind, globalLocation: CGPoint, code: UInt16 = 0, modifiers: UInt32 = 0) {
        guard let time = clock.mediaTime(forHost: clock.now) else { return }
        state.withLock { s in
            s.events.append(.init(
                time: time.seconds, kind: kind,
                x: Float(globalLocation.x - s.origin.x), y: Float(globalLocation.y - s.origin.y),
                code: code, modifiers: modifiers
            ))
        }
    }

    static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    // MARK: Clicks & keys

    private func startEventTap() {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: telemetryTapCallback, userInfo: userInfo
        )
        guard let created else {
            DispatchQueue.main.async { self.startFallbackMonitor() }
            return
        }
        tap = created
        capturesKeys = true
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "smoothcursor.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .otherMouseDown:
            record(.mouseDown, globalLocation: event.location)
        case .leftMouseUp, .otherMouseUp:
            record(.mouseUp, globalLocation: event.location)
        case .rightMouseDown:
            record(.rightDown, globalLocation: event.location)
        case .rightMouseUp:
            record(.rightUp, globalLocation: event.location)
        case .scrollWheel:
            let delta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            record(.scroll, globalLocation: event.location, code: UInt16(bitPattern: Int16(clamping: delta)))
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 || type == .keyDown else { return }
            record(
                type == .keyDown ? .keyDown : .keyUp, globalLocation: event.location,
                code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: UInt32(truncatingIfNeeded: event.flags.rawValue)
            )
        default:
            break
        }
    }

    @MainActor private func startFallbackMonitor() {
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        ) { [weak self] event in
            guard let self, let cg = event.cgEvent else { return }
            self.handle(type: cg.type, event: cg)
        }
    }

    // MARK: Cursor sprites

    @MainActor private func startSpriteSampling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(66), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sampleSprite() }
        }
        timer.resume()
        spriteTimer = timer
    }

    @MainActor private func sampleSprite() {
        guard let cursor = SystemCursor.current, let fingerprint = SystemCursor.fingerprint(cursor) else { return }
        if let index = state.withLock({ $0.spriteIndexByFingerprint[fingerprint] }) {
            state.withLock { $0.currentSprite = index }
            return
        }
        let index = state.withLock { UInt16($0.sprites.count) }
        let file = "\(PackagePaths.cursors)/\(index).png"
        guard SystemCursor.writePNG(cursor.image, to: packageURL.appending(path: file)) else { return }
        let sprite = Telemetry.CursorSprite(
            imageFile: file, hotspotX: cursor.hotSpot.x, hotspotY: cursor.hotSpot.y,
            width: cursor.image.size.width, height: cursor.image.size.height,
            kind: SystemCursor.kind(forFingerprint: fingerprint)
        )
        state.withLock { s in
            s.sprites.append(sprite)
            s.spriteIndexByFingerprint[fingerprint] = index
            s.currentSprite = index
        }
    }
}

private func telemetryTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<InputTelemetryRecorder>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

/// System cursor access and identification.
@MainActor
enum SystemCursor {
    /// `currentSystem` is soft-deprecated but remains the only way to read the global cursor image.
    static var current: NSCursor? { NSCursor.currentSystem }

    static func fingerprint(_ cursor: NSCursor) -> Int? {
        guard let cg = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data as Data? else { return nil }
        var hasher = Hasher()
        // `Data.hash(into:)` only looks at a prefix; cursor images start with transparent rows.
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        return hasher.finalize()
    }

    private static let known: [Int: String] = {
        let cursors: [(NSCursor, String)] = [
            (.arrow, "arrow"), (.iBeam, "iBeam"), (.pointingHand, "pointingHand"), (.openHand, "openHand"),
            (.closedHand, "closedHand"), (.crosshair, "crosshair"), (.operationNotAllowed, "notAllowed"),
            (.dragCopy, "dragCopy"), (.contextualMenu, "contextualMenu"), (.iBeamCursorForVerticalLayout, "iBeamVertical"),
            (.columnResize, "resizeLeftRight"), (.rowResize, "resizeUpDown"),
        ]
        var map: [Int: String] = [:]
        for (cursor, name) in cursors { if let f = fingerprint(cursor) { map[f] = name } }
        return map
    }()

    static func kind(forFingerprint fingerprint: Int) -> String? { known[fingerprint] }

    /// Writes the highest-resolution representation as PNG.
    static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        let best = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        let pixelSize = CGSize(width: best?.pixelsWide ?? Int(image.size.width), height: best?.pixelsHigh ?? Int(image.size.height))
        var rect = CGRect(origin: .zero, size: pixelSize)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
