import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutAutoGen
import LayoutVerify

/// The bridger inserts real geometry; these tests use a DRC rerun as the
/// oracle for whether the same-net sliver actually merged away, and
/// verify that different-net gaps and diagonal slivers are left alone.
@Suite("Same-net sliver bridger")
struct SameNetSliverBridgerTests {
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")

    @Test func bridgesHorizontalSameNetSliverAndDRCConfirms() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let netID = UUID()
        // Two same-net M2 rects 0.02µm apart with full vertical overlap:
        // a sliver below sampleProcess M2 min spacing.
        let left = LayoutShape(
            layer: m2,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        let right = LayoutShape(
            layer: m2,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.36, y: 0),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        var cell = LayoutCell(name: "TOP")
        cell.shapes = [left, right]
        var document = LayoutDocument(name: "TOP", cells: [cell], topCellID: cell.id)

        let before = LayoutDRCService().run(document: document, tech: tech)
        #expect(before.violations.contains { $0.kind == .minSpacing })

        let inserted = SameNetSliverBridger().bridge(document: &document, tech: tech)
        #expect(inserted == 1)

        let after = LayoutDRCService().run(document: document, tech: tech)
        #expect(!after.violations.contains { $0.kind == .minSpacing })
    }

    @Test func leavesDifferentNetGapAlone() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let left = LayoutShape(
            layer: m2,
            netID: UUID(),
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        let right = LayoutShape(
            layer: m2,
            netID: UUID(),
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.36, y: 0),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        var cell = LayoutCell(name: "TOP")
        cell.shapes = [left, right]
        var document = LayoutDocument(name: "TOP", cells: [cell], topCellID: cell.id)

        let inserted = SameNetSliverBridger().bridge(document: &document, tech: tech)
        #expect(inserted == 0)
        // A different-net sub-spacing gap is a REAL violation the router
        // must resolve; bridging it would short the nets.
        let after = LayoutDRCService().run(document: document, tech: tech)
        #expect(after.violations.contains { $0.kind == .minSpacing })
    }

    @Test func leavesDiagonalSliverAlone() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let netID = UUID()
        let lowerLeft = LayoutShape(
            layer: m2,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        // Offset in BOTH axes: corner-to-corner gap, no facing-edge
        // overlap for an axis-aligned bridge.
        let upperRight = LayoutShape(
            layer: m2,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.36, y: 0.36),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        var cell = LayoutCell(name: "TOP")
        cell.shapes = [lowerLeft, upperRight]
        var document = LayoutDocument(name: "TOP", cells: [cell], topCellID: cell.id)

        let inserted = SameNetSliverBridger().bridge(document: &document, tech: tech)
        #expect(inserted == 0)
    }

    @Test func leavesTouchingAndLegallySpacedPairsAlone() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let netID = UUID()
        let base = LayoutShape(
            layer: m2,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        let touching = LayoutShape(
            layer: m2,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.34, y: 0),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        let farAway = LayoutShape(
            layer: m2,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 2.0, y: 0),
                size: LayoutSize(width: 0.34, height: 0.34)
            ))
        )
        var cell = LayoutCell(name: "TOP")
        cell.shapes = [base, touching, farAway]
        var document = LayoutDocument(name: "TOP", cells: [cell], topCellID: cell.id)

        let inserted = SameNetSliverBridger().bridge(document: &document, tech: tech)
        #expect(inserted == 0)
    }
}
