import Foundation
import Testing
@testable import SCCore

@Suite struct TimelineEditTests {
    func zooms() -> [ZoomSegment] {
        [ZoomSegment(range: TimeRange(start: 1, end: 3), origin: .auto),
         ZoomSegment(range: TimeRange(start: 5, end: 7), origin: .auto)]
    }

    @Test func singleMoveStopsAtNeighbour() {
        let z = zooms()
        let moved = ZoomEdits.move(z, ids: [z[0].id], by: 10, duration: 20)
        #expect(moved[0].range == TimeRange(start: 3, end: 5))
        #expect(moved[0].origin == .manual && moved[1].origin == .auto)
    }

    @Test func groupMoveStaysInsideRecording() {
        let z = zooms()
        let moved = ZoomEdits.move(z, ids: Set(z.map(\.id)), by: -5, duration: 20)
        #expect(moved[0].range.start == 0 && moved[1].range.start == 4)
    }

    @Test func resizeClampsToNeighbourAndMinimum() {
        let z = zooms()
        #expect(ZoomEdits.resize(z, id: z[0].id, edge: .end, to: 9, duration: 20)[0].range.end == 5)
        #expect(ZoomEdits.resize(z, id: z[0].id, edge: .start, to: 2.9, duration: 20)[0].range.start == 3 - ZoomEdits.minDuration)
    }

    @Test func insertionFitsFreeSpace() {
        let z = zooms()
        #expect(ZoomEdits.insertion(at: 2, in: z, duration: 20) == nil) // inside a zoom
        let new = ZoomEdits.insertion(at: 3.5, in: z, duration: 20)!
        #expect(new.range == TimeRange(start: 3.5, end: 5))
    }

    @Test func snappingPicksNearestEdge() {
        #expect(Snapping.snap(2.05, to: [0, 2, 4], threshold: 0.1) == 2)
        #expect(Snapping.snap(2.5, to: [0, 2, 4], threshold: 0.1) == 2.5)
        let d = Snapping.snapDelta(range: TimeRange(start: 1, end: 3), delta: 0.95, candidates: [4], threshold: 0.1)
        #expect(abs(d - 1) < 1e-9) // end snapped onto 4
    }

    func project() -> Project {
        Project(name: "T", recording: RecordingInfo(sourceKind: .display, videoFile: "v", pixelSize: PixelSize(width: 10, height: 10), displayScale: 1, fps: 60, duration: 10))
    }

    @Test func splitTrimRemoveClips() {
        var p = project()
        p.cuts = Cuts.split(p, at: 4)!
        #expect(p.cuts == [TimeRange(start: 0, end: 4), TimeRange(start: 4, end: 10)])
        p.cuts = Cuts.trim(p, index: 1, edge: .start, to: 6)
        #expect(Cuts.editedDuration(p) == 8)
        #expect(Cuts.nextKeptTime(after: 5, in: Cuts.kept(p)) == 6)
        p.cuts = Cuts.remove(p, index: 0)!
        #expect(Cuts.kept(p) == [TimeRange(start: 6, end: 10)])
        #expect(Cuts.remove(p, index: 0) == nil) // last clip stays
        p.cuts = Cuts.trim(p, index: 0, edge: .start, to: -1)
        #expect(p.cuts.isEmpty) // back to "everything"
    }
}

@Suite struct ExportMathTests {
    @Test func timeMappingThroughCuts() {
        let kept = [TimeRange(start: 0, end: 4), TimeRange(start: 6, end: 10)]
        #expect(Cuts.sourceTime(forOutput: 3, in: kept) == 3)
        #expect(Cuts.sourceTime(forOutput: 5, in: kept) == 7)
        #expect(Cuts.outputTime(forSource: 7, in: kept) == 5)
        #expect(Cuts.outputTime(forSource: 5, in: kept) == nil)
    }

    @Test func outputSizesUseShortSide() {
        var e = ExportSettings()
        e.height = 1080
        #expect(e.outputSize(aspect: 16.0 / 9) == PixelSize(width: 1920, height: 1080))
        #expect(e.outputSize(aspect: 9.0 / 16) == PixelSize(width: 1080, height: 1920))
        e.format = .gif
        e.height = 2160
        #expect(e.outputSize(aspect: 1).width == 720)
        #expect(e.effectiveFPS == 30)
    }
}

@Suite struct IdleTrimTests {
    @Test func removesTheMiddleOfLongIdleStretches() {
        let p = Project(name: "T", recording: RecordingInfo(sourceKind: .display, videoFile: "v", pixelSize: PixelSize(width: 10, height: 10), displayScale: 1, fps: 60, duration: 20))
        // Activity until 3 s, nothing until 12 s, then activity again.
        var events: [Telemetry.Event] = []
        for i in 0...30 { events.append(.init(time: Double(i) / 10, kind: .move, x: Float(i), y: 0)) }
        for i in 120...200 { events.append(.init(time: Double(i) / 10, kind: .move, x: Float(i), y: 0)) }
        let t = Telemetry(header: .init(targetSize: PixelSize(width: 100, height: 100), displayScale: 1), events: events)
        let kept = IdleTrim.keptRanges(project: p, telemetry: t, peaks: [])
        #expect(kept == [TimeRange(start: 0, end: 3.4), TimeRange(start: 11.6, end: 20)])
        // Talking during the pause keeps it.
        let speech = (0..<2000).map { i -> Float in (500...700).contains(i) ? 0.5 : 0 }
        let withVoice = IdleTrim.keptRanges(project: p, telemetry: t, peaks: speech)
        #expect(withVoice == [TimeRange(start: 0, end: 7.4), TimeRange(start: 11.6, end: 20)])
    }
}
