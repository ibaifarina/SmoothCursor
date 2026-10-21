@preconcurrency import AVFoundation
import Observation
import SCCore

/// Plays a recording for the editor: AVPlayer for decoding and audio, with video frames pulled
/// by the Metal preview at display refresh rate. Seeks are frame-accurate and coalesced
/// ("chase" seeking) so scrubbing stays responsive.
@MainActor
@Observable
public final class PlaybackController {
    /// Playhead in seconds. Updated ~30×/s while playing; immediately on seek.
    public private(set) var time: Seconds = 0
    public private(set) var isPlaying = false
    public let duration: Seconds
    public let frameDuration: Seconds

    @ObservationIgnored public let player: AVPlayer
    @ObservationIgnored let output: AVPlayerItemVideoOutput
    /// Called when the preview should wake up (play, seek, new frame expected).
    @ObservationIgnored public var onActivity: (() -> Void)?

    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var boundaryObserver: Any?

    /// Parts of the recording that are kept; playback jumps over everything else. Empty = all.
    @ObservationIgnored public var keptRanges: [TimeRange] = [] {
        didSet { if keptRanges != oldValue { installBoundaries() } }
    }
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSeek: CMTime?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var resumeAfterScrub = false

    public var isSeeking: Bool { seekInFlight }

    public init(url: URL, duration: Seconds, fps: Double) {
        self.duration = duration
        frameDuration = 1 / max(fps, 1)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        // A paused player decodes nothing until it seeks: show the first frame once ready.
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self else { return }
                self.seek(to: self.time)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.seekInFlight else { return }
                self.time = min(max(t.seconds, 0), self.duration)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.time = self?.duration ?? 0
            }
        }
    }

    public func invalidate() {
        player.pause()
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        statusObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    // MARK: Transport

    public func togglePlay() { isPlaying ? pause() : play() }

    public func play() {
        if time >= (keptRanges.last?.end ?? duration) - frameDuration { seek(to: keptRanges.first?.start ?? 0) }
        if !keptRanges.isEmpty, let next = Cuts.nextKeptTime(after: time, in: keptRanges), next != time { seek(to: next) }
        isPlaying = true
        player.play()
        onActivity?()
    }

    public func pause() {
        isPlaying = false
        player.pause()
        time = min(max(player.currentTime().seconds, 0), duration)
        onActivity?()
    }

    public func step(frames: Int) {
        if isPlaying { pause() }
        seek(to: time + Double(frames) * frameDuration)
    }

    /// Frame-accurate seek; rapid calls collapse onto the latest target.
    public func seek(to seconds: Seconds) {
        let clamped = min(max(seconds, 0), duration)
        time = clamped
        pendingSeek = CMTime(seconds: clamped, preferredTimescale: 60_000)
        onActivity?()
        if !seekInFlight { startNextSeek() }
    }

    /// Scrubbing pauses playback and resumes it afterwards.
    public func beginScrub() {
        resumeAfterScrub = isPlaying
        if isPlaying { pause() }
    }

    public func endScrub() {
        if resumeAfterScrub { play() }
        resumeAfterScrub = false
    }

    /// At the end of each kept range, jump to the next one (or stop after the last).
    private func installBoundaries() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        guard !keptRanges.isEmpty else { return }
        let ends = keptRanges.map { NSValue(time: CMTime(seconds: $0.end, preferredTimescale: 60_000)) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: ends, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                let now = self.player.currentTime().seconds
                let ranges = self.keptRanges
                guard let ended = ranges.indices.min(by: { abs(ranges[$0].end - now) < abs(ranges[$1].end - now) }) else { return }
                if ended + 1 < ranges.count {
                    self.seek(to: ranges[ended + 1].start)
                } else {
                    self.pause()
                }
            }
        }
    }

    private func startNextSeek() {
        guard let target = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                self.onActivity?()
                if self.pendingSeek != nil { self.startNextSeek() }
            }
        }
    }

    // MARK: Frames (for the preview)

    /// Item time that will be on screen at the given host time (e.g. a display link's target timestamp).
    public func itemTime(forHostTime hostTime: CFTimeInterval) -> Seconds {
        if !isPlaying { return time }
        let t = output.itemTime(forHostTime: hostTime)
        return t.isNumeric ? min(max(t.seconds, 0), duration) : time
    }

    /// A newly decoded frame for `itemTime`, or nil if the current one is still valid.
    public func newPixelBuffer(forItemTime itemTime: Seconds) -> CVPixelBuffer? {
        let t = CMTime(seconds: itemTime, preferredTimescale: 60_000)
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }
}
