import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Contract of `DRDDragSession`: every proposal verifies against the live
/// incremental session — the same oracle signoff uses — legality means
/// "no violation identity beyond the drag-origin baseline", and enforce
/// mode resolves an illegal proposal to the furthest legal grid step
/// along the path from the last legal offset.
@Suite("DRDDragSession", .timeLimit(.minutes(5)))
struct DRDDragSessionTests {

    private struct Fixture {
        var document: LayoutDocument
        var tech: LayoutTechDatabase
        var m1: LayoutLayerID
        var anchor: LayoutShape
        var rover: LayoutShape
    }

    /// One 1x0.4 anchor at the origin and one 1x0.4 rover at a
    /// configurable origin; m1 minSpacing 0.23 on a 0.01 grid. The rover
    /// is legal at the default origin (gap 2.0) and violating at
    /// x = 1.2 (gap 0.2).
    private static func makeFixture(
        roverOrigin: LayoutPoint = LayoutPoint(x: 3.0, y: 0),
        extraShapes: [LayoutShape] = []
    ) -> Fixture {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let tech = LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: m1,
                    displayName: "M1",
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
                )
            ],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1,
                    minWidth: 0.23,
                    minSpacing: 0.23,
                    minArea: 0.1,
                    minDensity: 0.0,
                    maxDensity: 1.0
                )
            ]
        )
        let anchor = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1.0, height: 0.4)))
        )
        let rover = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(origin: roverOrigin, size: LayoutSize(width: 1.0, height: 0.4)))
        )
        let cell = LayoutCell(name: "TOP", shapes: [anchor, rover] + extraShapes)
        let document = LayoutDocument(name: "drd-fixture", cells: [cell], topCellID: cell.id)
        return Fixture(document: document, tech: tech, m1: m1, anchor: anchor, rover: rover)
    }

    private static func makeSession(_ fixture: Fixture) throws -> IncrementalDRCSession {
        try IncrementalDRCSession(document: fixture.document, tech: fixture.tech)
    }

    // MARK: - Enforce resolution

    @Test func enforceResolvesToFurthestLegalGridStep() throws {
        let fixture = Self.makeFixture()
        let session = try Self.makeSession(fixture)
        #expect(session.currentResult.violations.isEmpty, "fixture must start clean")
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)

        // Proposal puts the rover 0.05 from the anchor — illegal. The
        // furthest legal grid step keeps the gap at exactly minSpacing:
        // rover.minX = 1.23, i.e. offset.x = -1.77.
        let resolution = try drag.propose(offset: LayoutPoint(x: -1.95, y: 0), enforce: true)
        #expect(resolution.outcome == .constrained)
        #expect(abs(resolution.appliedOffset.x - (-1.77)) < 1e-9)
        #expect(abs(resolution.appliedOffset.y) < 1e-9)
        #expect(
            !resolution.result.violations.contains { $0.kind == .minSpacing },
            "the resolved position must be violation-free"
        )

        // The next grid step toward the anchor is illegal, so a further
        // proposal cannot advance at all.
        let nudge = try drag.propose(offset: LayoutPoint(x: -1.78, y: 0), enforce: true)
        #expect(nudge.outcome == .blocked)
        #expect(abs(nudge.appliedOffset.x - (-1.77)) < 1e-9)
    }

    @Test func enforcedResolutionMatchesIndependentOracle() throws {
        // The engine's resolved offset must agree with a from-scratch
        // batch probe of every grid step along the drag direction.
        let fixture = Self.makeFixture()
        let session = try Self.makeSession(fixture)
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)
        let proposalX = -1.95

        let resolution = try drag.propose(offset: LayoutPoint(x: proposalX, y: 0), enforce: true)

        let service = LayoutDRCService()
        var furthestLegalX = 0.0
        var step = 1
        while true {
            let candidate = (Double(-step) * 0.01)
            if candidate < proposalX { break }
            var document = fixture.document
            var cell = document.cells[0]
            let index = try #require(cell.shapes.firstIndex { $0.id == fixture.rover.id })
            var moved = fixture.rover
            moved.geometry = fixture.rover.geometry.translated(by: LayoutPoint(x: candidate, y: 0))
            cell.shapes[index] = moved
            document.updateCell(cell)
            let probe = service.run(document: document, tech: fixture.tech)
            if probe.violations.isEmpty {
                furthestLegalX = candidate
            } else {
                break
            }
            step += 1
        }
        #expect(
            abs(resolution.appliedOffset.x - furthestLegalX) < 1e-9,
            "engine resolved \(resolution.appliedOffset.x), oracle says \(furthestLegalX)"
        )
    }

    // MARK: - Observe mode

    @Test func observeReportsWithoutConstraining() throws {
        let fixture = Self.makeFixture()
        let session = try Self.makeSession(fixture)
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)

        let resolution = try drag.propose(offset: LayoutPoint(x: -1.95, y: 0), enforce: false)
        #expect(resolution.outcome == .followed)
        #expect(abs(resolution.appliedOffset.x - (-1.95)) < 1e-9)
        #expect(
            resolution.result.violations.contains {
                $0.kind == .minSpacing && $0.shapeIDs.contains(fixture.rover.id)
            },
            "observe mode must land in the violation and report it"
        )
    }

    // MARK: - Baseline semantics

    @Test func baselineViolationDoesNotBlockDrag() throws {
        // The rover starts in violation (gap 0.2 < 0.23). Dragging it
        // while the same identity persists must stay legal — a violating
        // shape can always be moved.
        let fixture = Self.makeFixture(roverOrigin: LayoutPoint(x: 1.2, y: 0))
        let session = try Self.makeSession(fixture)
        #expect(session.currentResult.violations.contains { $0.kind == .minSpacing })
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)

        let resolution = try drag.propose(offset: LayoutPoint(x: 0.01, y: 0), enforce: true)
        #expect(resolution.outcome == .followed)
        #expect(
            resolution.result.violations.contains { $0.kind == .minSpacing },
            "the baseline violation persists at the new position"
        )
    }

    @Test func newViolationPairConstrainsEvenWithBaselineViolation() throws {
        // Rover violates against the anchor at the origin side; a second
        // anchor sits to the right. Dragging right must stop before a NEW
        // pair forms, even though the baseline violation excuses the old
        // pair.
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let secondAnchor = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 2.5, y: 0),
                size: LayoutSize(width: 1.0, height: 0.4)
            ))
        )
        let fixture = Self.makeFixture(
            roverOrigin: LayoutPoint(x: 1.2, y: 0),
            extraShapes: [secondAnchor]
        )
        let session = try Self.makeSession(fixture)
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)

        // Legal against the second anchor: 2.5 - (2.2 + dx) >= 0.23,
        // i.e. dx <= 0.07.
        let resolution = try drag.propose(offset: LayoutPoint(x: 0.25, y: 0), enforce: true)
        #expect(resolution.outcome == .constrained)
        #expect(abs(resolution.appliedOffset.x - 0.07) < 1e-9)
        #expect(
            !resolution.result.violations.contains {
                $0.shapeIDs.contains(fixture.rover.id) && $0.shapeIDs.contains(secondAnchor.id)
            },
            "no rover/second-anchor pair may form"
        )
    }

    @Test func sameLayerOverlapMergesAndStaysLegal() throws {
        // Overlap on the same layer merges into one component, so a
        // proposal that lands the rover ON the anchor is legal even
        // though the path crosses the illegal gap band.
        let fixture = Self.makeFixture()
        let session = try Self.makeSession(fixture)
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)

        let resolution = try drag.propose(offset: LayoutPoint(x: -2.5, y: 0), enforce: true)
        #expect(resolution.outcome == .followed)
        #expect(abs(resolution.appliedOffset.x - (-2.5)) < 1e-9)
        #expect(!resolution.result.violations.contains { $0.kind == .minSpacing })
    }

    @Test func fullyBoxedDragIsBlocked() throws {
        // Rover sits at exactly minSpacing from anchors on both sides;
        // every horizontal grid step creates a new violation.
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let rightAnchor = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 2.46, y: 0),
                size: LayoutSize(width: 1.0, height: 0.4)
            ))
        )
        let fixture = Self.makeFixture(
            roverOrigin: LayoutPoint(x: 1.23, y: 0),
            extraShapes: [rightAnchor]
        )
        let session = try Self.makeSession(fixture)
        #expect(session.currentResult.violations.isEmpty, "exact-minSpacing gaps must start clean")
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)

        let left = try drag.propose(offset: LayoutPoint(x: -0.05, y: 0), enforce: true)
        #expect(left.outcome == .blocked)
        #expect(abs(left.appliedOffset.x) < 1e-9)

        let right = try drag.propose(offset: LayoutPoint(x: 0.05, y: 0), enforce: true)
        #expect(right.outcome == .blocked)
        #expect(abs(right.appliedOffset.x) < 1e-9)
    }

    // MARK: - Cancel & quantization

    @Test func cancelRestoresOrigin() throws {
        let fixture = Self.makeFixture()
        let session = try Self.makeSession(fixture)
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)

        _ = try drag.propose(offset: LayoutPoint(x: -1.95, y: 0), enforce: true)
        let restored = try drag.cancel()
        #expect(restored.violations.isEmpty)
        #expect(drag.currentOffset == .zero)

        // The session snapshot must equal a from-scratch run on the
        // original document.
        let reference = LayoutDRCService().run(document: fixture.document, tech: fixture.tech)
        #expect(
            IncrementalDRCEquivalenceHarness.canonicalCounts(restored.violations, excludingAntenna: false)
                == IncrementalDRCEquivalenceHarness.canonicalCounts(reference.violations, excludingAntenna: false)
        )
    }

    @Test func proposalsQuantizeToGrid() throws {
        let fixture = Self.makeFixture()
        let session = try Self.makeSession(fixture)
        let drag = DRDDragSession(session: session, shapes: [fixture.rover], grid: fixture.tech.grid)

        let resolution = try drag.propose(
            offset: LayoutPoint(x: -0.4549, y: 0.0037),
            enforce: false
        )
        #expect(abs(resolution.appliedOffset.x - (-0.45)) < 1e-9)
        #expect(abs(resolution.appliedOffset.y) < 1e-9)
    }
}
