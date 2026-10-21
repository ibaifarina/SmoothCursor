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
