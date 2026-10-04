import Foundation
import Testing
import LayoutCore
import LayoutTech
@testable import LayoutVerify

/// Stress tests for the cluster-granular width/area/spacing maintenance in
/// `IncrementalDRCSession`: every partition transition an edit can cause —
/// merge by abutment or overlap, corner contact, halo-coupled gaps, chain
/// merges across many clusters, atomic rejection of unsupported geometry,
/// degenerate geometry rejection, and ID reuse after
/// removal — must keep the live snapshot equal to a from-scratch full run.
@Suite("IncrementalDRC Cluster Transitions", .timeLimit(.minutes(5)))
struct IncrementalDRCClusterTests {

    /// Walks one shape pair through every spatial relation that changes
    /// the cluster partition: far apart (two clusters), abutting and
    /// overlapping (one component), corner-only contact, a violating gap,
    /// a halo-coupled legal gap, and back to far apart.
    @Test func clusterMergeAndSplitTransitions() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        let anchor = LayoutShape(
            layer: fixture.m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 8.5),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        var rover = LayoutShape(
            layer: fixture.m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 3, y: 8.5),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        try harness.applyAndVerify(
            LayoutEditDelta(addedShapes: [anchor, rover]),
            context: "anchor and rover added far apart"
        )

        func move(to origin: LayoutPoint, context: String) throws {
            rover.geometry = .rect(LayoutRect(
                origin: origin,
                size: LayoutSize(width: 1, height: 0.4)
            ))
            try harness.applyAndVerify(
                LayoutEditDelta(updatedShapes: [rover]),
                context: context
            )
        }

        try move(to: LayoutPoint(x: 1, y: 8.5), context: "rover abuts anchor: clusters merge")
        try move(to: LayoutPoint(x: 0.8, y: 8.5), context: "rover overlaps anchor")
        try move(to: LayoutPoint(x: 1, y: 8.1), context: "corner-only contact")
        try move(to: LayoutPoint(x: 1.1, y: 8.5), context: "violating 0.1um gap")
        try move(to: LayoutPoint(x: 1.4, y: 8.5), context: "legal gap still inside the halo")
        try move(to: LayoutPoint(x: 3, y: 8.5), context: "rover far again: clusters split")
    }

    /// A wire landing across a row of mutually independent pads must
    /// collapse them into one cluster, and its removal must split them
    /// back — the largest partition change a single edit can cause.
    @Test func chainMergeCollapsesManyClusters() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        let pads = (0..<8).map { column in
            LayoutShape(
                layer: fixture.m2,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: Double(column), y: 10),
                    size: LayoutSize(width: 0.4, height: 0.4)
                ))
            )
        }
        try harness.applyAndVerify(
            LayoutEditDelta(addedShapes: pads),
            context: "pad row added: one cluster per pad"
        )

        let spanningWire = LayoutShape(
            layer: fixture.m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 10),
                size: LayoutSize(width: 7.4, height: 0.4)
            ))
        )
        try harness.applyAndVerify(
            LayoutEditDelta(addedShapes: [spanningWire]),
            context: "spanning wire chain-merges all pad clusters"
        )
        try harness.applyAndVerify(
            LayoutEditDelta(removedShapeIDs: [spanningWire.id]),
            context: "spanning wire removed: clusters split back"
        )
    }

    /// The canonical exact kernel rejects non-rectilinear geometry. The
    /// rejection must be typed and atomic so later valid edits still work.
    @Test func nonManhattanLayerIsRejectedAtomicallyAndSessionRecovers() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        let bender = LayoutShape(
            layer: fixture.m1,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 5, y: 5),
                LayoutPoint(x: 6, y: 5),
                LayoutPoint(x: 6, y: 6),
            ]))
        )
        let snapshotBeforeRejection = harness.session.currentResult
        #expect(throws: IncrementalDRCSessionError.unsupportedNonRectilinearGeometry(shapeID: bender.id)) {
            _ = try harness.session.apply(LayoutEditDelta(addedShapes: [bender]))
        }
        #expect(harness.session.currentResult == snapshotBeforeRejection)

        var nudgedWire = fixture.wireA
        nudgedWire.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 0, y: 0.1),
            size: LayoutSize(width: 8, height: 0.4)
        ))
        try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [nudgedWire]),
            context: "valid edit after rejected non-rectilinear geometry"
        )
        try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [fixture.wireA]),
            context: "incremental clustering works again after recovery"
        )
    }

    /// A two-point polygon is not an electrical conductor. The physical
    /// contributor oracle still records its marker incidence, while native
    /// session admission rejects it without replacing the valid generation.
    @Test func degenerateShapeJoinsContributorClusters() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        let left = LayoutShape(
            layer: fixture.m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 12),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        let right = LayoutShape(
            layer: fixture.m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.5, y: 12),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        let degenerate = LayoutShape(
            layer: fixture.m2,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0.35, y: 12.1),
                LayoutPoint(x: 0.55, y: 12.3),
            ]))
        )
        _ = try harness.applyAndVerify(LayoutEditDelta(addedShapes: [left, right]), context: "valid spacing pair")
        let before = harness.session.currentResult
        #expect(throws: LayoutConductorCaptureError.self) {
            try harness.session.apply(LayoutEditDelta(addedShapes: [degenerate]))
        }
        #expect(harness.session.currentResult == before)
        let physical = try LayoutDRCService().checkSpacing(shapes: [left, right, degenerate], tech: fixture.tech)
        let spacing = physical.first {
            $0.kind == .minSpacing && $0.shapeIDs.contains(left.id) && $0.shapeIDs.contains(right.id)
        }
        #expect(spacing?.shapeIDs.contains(degenerate.id) == true,
                "the physical marker contributor remains independently verified")
    }

    /// Removing a shape and later re-adding its UUID elsewhere is a legal
    /// delta sequence; stale cluster membership or cached density terms
    /// keyed to the old occurrence must not leak into the new one.
    @Test func removedShapeIDReaddedElsewhere() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        try harness.applyAndVerify(
            LayoutEditDelta(removedShapeIDs: [fixture.padB.id]),
            context: "pad B removed"
        )
        let reborn = LayoutShape(
            id: fixture.padB.id,
            layer: fixture.m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 4.5, y: 0.5),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        try harness.applyAndVerify(
            LayoutEditDelta(addedShapes: [reborn]),
            context: "pad B's UUID re-added at a different location"
        )

        var moved = reborn
        moved.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 4.5, y: 1.2),
            size: LayoutSize(width: 0.4, height: 0.4)
        ))
        try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [moved]),
            context: "re-added shape edited again"
        )
    }
}
