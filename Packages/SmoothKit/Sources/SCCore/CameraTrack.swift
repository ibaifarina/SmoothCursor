import CoreGraphics
import Foundation

/// Camera motion for a whole project, precomputed at 120 Hz from its zoom segments.
///
/// - Follow-cursor zooms keep the cursor inside a dead zone and move with the segment's spring.
/// - Segments closer together than `handoffGap` form a chain: the camera pans from one to the
///   next instead of zooming out and back in, easing out slightly on long pans.
/// - Everything is stored as fractions of the canvas, so any output size gets the same motion.
public struct CameraTrack: Sendable {
    public static let rate = 120.0
    public static let handoffGap: Seconds = 0.9

    /// Visible canvas rect per sample, as fractions of the canvas (x, y, width, height). Empty = never zooms.
    private let samples: [SIMD4<Double>]

    public init(project: Project, cursor: CursorTrack?) {
        let aspect = FrameLayout.outputAspect(for: project)
        let canvas = CGSize(width: 1000, height: 1000 / max(aspect, 0.01))
        let layout = FrameLayout.base(project: project, outputSize: canvas)
        let zooms = project.zooms
            .filter { $0.scale > 1.0001 && $0.range.duration > 0.01 }
            .sorted { $0.range.start < $1.range.start }
        guard !zooms.isEmpty else { samples = []; return }

        let toCanvas = cursor.map { layout.mapping(targetSize: $0.targetSize) }
        let builder = Builder(
            canvas: canvas, screen: layout.screenRect, crop: layout.sourceCrop,
            cursor: cursor, toCanvas: toCanvas, zooms: zooms
        )
        let count = Int((project.recording.duration * Self.rate).rounded(.up)) + 1
        samples = (0..<count).map { i in
            let r = builder.rect(at: Double(i) / Self.rate)
            return SIMD4(r.minX / canvas.width, r.minY / canvas.height, r.width / canvas.width, r.height / canvas.height)
        }
    }

    /// Visible part of the canvas at `time`, as fractions of the canvas.
    public func visibleUnitRect(at time: Seconds) -> CGRect {
        guard !samples.isEmpty else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let i = time * Self.rate
        let a = Int(min(max(floor(i), 0), Double(samples.count - 1)))
        let b = min(a + 1, samples.count - 1)
        let f = min(max(i - Double(a), 0), 1)
        let s = samples[a] + (samples[b] - samples[a]) * f
        return CGRect(x: s.x, y: s.y, width: s.z, height: s.w)
    }

    public func camera(at time: Seconds, outputSize: CGSize) -> FrameLayout.Camera {
        guard !samples.isEmpty else { return .identity }
        let u = visibleUnitRect(at: time)
        let rect = CGRect(x: u.minX * outputSize.width, y: u.minY * outputSize.height,
                          width: u.width * outputSize.width, height: u.height * outputSize.height)
        return ZoomCamera.camera(showing: rect, outputSize: outputSize)
    }
}

// MARK: - Building

private struct Builder {
    let canvas: CGSize
    let screen: CGRect
    let crop: UnitRect
    let zooms: [ZoomSegment]
    /// Per zoom: canvas focus over its range, sampled at `CameraTrack.rate` (fixed focus: one point).
    let focus: [[CGPoint]]
    let chains: [[Int]]

    init(canvas: CGSize, screen: CGRect, crop: UnitRect, cursor: CursorTrack?, toCanvas: ((CGPoint) -> CGPoint)?, zooms: [ZoomSegment]) {
        self.canvas = canvas
        self.screen = screen
        self.crop = crop
        self.zooms = zooms

        let center = CGPoint(x: screen.midX, y: screen.midY)
        focus = zooms.map { zoom in
            switch zoom.focus {
            case let .fixed(p):
                return [CGPoint(
                    x: screen.minX + (p.x - crop.x) / crop.width * screen.width,
                    y: screen.minY + (p.y - crop.y) / crop.height * screen.height
                )]
            case let .followCursor(deadZone):
                guard let cursor, let toCanvas else { return [center] }
                return Self.follow(zoom: zoom, deadZone: deadZone, cursor: cursor, toCanvas: toCanvas, canvas: canvas, screen: screen)
            }
        }

        var chains: [[Int]] = []
        var chainEnd = -Double.infinity
        for (i, z) in zooms.enumerated() {
            if !chains.isEmpty, z.range.start - chainEnd <= CameraTrack.handoffGap {
                chains[chains.count - 1].append(i)
                chainEnd = max(chainEnd, z.range.end)
            } else {
                chains.append([i])
                chainEnd = z.range.end
            }
        }
        self.chains = chains
    }

    func rect(at t: Seconds) -> CGRect {
        let full = CGRect(origin: .zero, size: canvas)
        guard let chain = chains.first(where: { c in
            t >= zooms[c[0]].range.start && t <= c.map { zooms[$0].range.end }.max()!
        }) else { return full }

        let first = zooms[chain[0]]
        let last = chain.map { zooms[$0] }.max { $0.range.end < $1.range.end }!
        let zoomIn = first.transitionIn > 0 ? first.easing.value((t - first.range.start) / first.transitionIn) : 1
        let zoomOut = last.transitionOut > 0 ? last.easing.value((last.range.end - t) / last.transitionOut) : 1
        let amount = min(zoomIn, zoomOut)
        return ZoomCamera.interpolate(from: full, to: chainRect(chain, at: t), amount: min(max(amount, 0), 1.2))
    }

    /// Fully zoomed rect inside a chain, with eased pans between members.
    private func chainRect(_ chain: [Int], at t: Seconds) -> CGRect {
        for k in 0..<(chain.count - 1) {
            let a = chain[k], b = chain[k + 1]
            let endA = zooms[a].range.end, startB = zooms[b].range.start
            let boundary = (endA + startB) / 2
            let half = max(zooms[b].transitionIn, 0.5) / 2
            let lo = min(boundary - half, endA), hi = max(boundary + half, startB)
            if t < lo { return memberRect(a, at: t) }
            if t <= hi {
                let p = zooms[b].easing.value((t - lo) / max(hi - lo, 1e-6))
                let from = memberRect(a, at: min(t, endA)), to = memberRect(b, at: max(t, startB))
                return dip(ZoomCamera.interpolate(from: from, to: to, amount: p), from: from, to: to, progress: p)
            }
        }
        return memberRect(chain[chain.count - 1], at: t)
    }

    private func memberRect(_ i: Int, at t: Seconds) -> CGRect {
        let path = focus[i]
        let index = Int(((t - zooms[i].range.start) * CameraTrack.rate).rounded())
        let f = path[min(max(index, 0), path.count - 1)]
        return ZoomCamera.targetRect(scale: zooms[i].scale, focus: f, canvas: canvas, screen: screen, staysInRecording: zooms[i].staysInRecording)
    }

    /// Long pans pull back a little mid-way so the viewer keeps their bearings.
    private func dip(_ r: CGRect, from a: CGRect, to b: CGRect, progress p: Double) -> CGRect {
        let distance = hypot(b.midX - a.midX, b.midY - a.midY)
        let amount = 0.3 * min(distance / max(a.width, 1), 1) * sin(.pi * p)
        guard amount > 0.001 else { return r }
        var w = min(r.width * (1 + amount), canvas.width)
        var h = w * r.height / r.width
        if h > canvas.height { h = canvas.height; w = h * r.width / r.height }
        let x = min(max(r.midX - w / 2, 0), canvas.width - w)
        let y = min(max(r.midY - h / 2, 0), canvas.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Spring camera that only moves when the cursor leaves the central dead zone.
    static func follow(
        zoom: ZoomSegment, deadZone: Double, cursor: CursorTrack, toCanvas: (CGPoint) -> CGPoint,
        canvas: CGSize, screen: CGRect
    ) -> [CGPoint] {
        let rate = CameraTrack.rate
        let start = zoom.range.start
        let count = Int((zoom.range.duration * rate).rounded(.up)) + 1
        let view = CGSize(width: canvas.width / zoom.scale, height: canvas.height / zoom.scale)
        let margin = min(max(deadZone, 0), 0.45)
        // The cursor may roam this far from the camera center before the camera moves.
        let free = CGSize(width: view.width * (0.5 - margin), height: view.height * (0.5 - margin))

        func clamp(_ c: CGPoint) -> CGPoint {
            let r = ZoomCamera.targetRect(scale: zoom.scale, focus: c, canvas: canvas, screen: screen, staysInRecording: zoom.staysInRecording)
            return CGPoint(x: r.midX, y: r.midY)
        }
        func cursorAt(_ t: Seconds) -> CGPoint? { cursor.displayedPosition(at: t).map(toCanvas) }

        // Aim where the action is once fully zoomed in, not where the cursor was when zooming began.
        let settle = start + min(zoom.transitionIn, zoom.range.duration)
        var target = clamp(cursorAt(settle) ?? CGPoint(x: screen.midX, y: screen.midY))
        var c = target
        var v = CGVector.zero
        let spring = zoom.followSpring
        let omega = spring.omega0, zeta = spring.zeta
        let h = 1 / rate / 2

        var path: [CGPoint] = []
        path.reserveCapacity(count)
        for i in 0..<count {
            let t = start + Double(i) / rate
            if t >= settle, let p = cursorAt(t) {
                if p.x > target.x + free.width { target.x = p.x - free.width }
                if p.x < target.x - free.width { target.x = p.x + free.width }
                if p.y > target.y + free.height { target.y = p.y - free.height }
                if p.y < target.y - free.height { target.y = p.y + free.height }
                target = clamp(target)
            }
            for _ in 0..<2 {
                let ax = (target.x - c.x) * omega * omega - v.dx * 2 * zeta * omega
                let ay = (target.y - c.y) * omega * omega - v.dy * 2 * zeta * omega
                v.dx += ax * h
                v.dy += ay * h
                c.x += v.dx * h
                c.y += v.dy * h
            }
            path.append(c)
        }
        return path
    }
}
