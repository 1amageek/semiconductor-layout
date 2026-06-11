import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Equivalence contract of `LiveConnectivitySession`: after any sequence
/// of geometry deltas, the live analysis must equal a from-scratch batch
/// extraction of the identically edited document — bit-exactly, because
/// both engines assemble through one canonical component order.
@Suite("LiveConnectivitySession", .timeLimit(.minutes(5)))
struct LiveConnectivitySessionTests {

    // MARK: - Randomized property test

    @Test func randomizedEditSequenceMatchesBatchExtraction() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try LiveConnectivityEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )
        let seed: UInt64 = 0x5EED_C0DE_2026_0003
        var rng = SplitMix64(seed: seed)

        for step in 0..<60 {
            let delta = Self.randomDelta(
                rng: &rng,
                topShapes: harness.topShapes,
                topVias: harness.topVias,
                fixture: fixture
            )
            try harness.applyAndVerify(delta, context: "seed \(seed) step \(step)")
        }
    }

    // MARK: - Deterministic scenarios

    @Test func viaRemovalOpensTheNetAndRestoreClosesIt() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try LiveConnectivityEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )
        let viaB = fixture.viaB

        let broken = try harness.applyAndVerify(
            LayoutEditDelta(removedViaIDs: [viaB.id]),
            context: "remove via B"
        )
        let open = try #require(
            broken.analysis.opens.first { $0.netID == fixture.netB },
            "without its via, net B's M2 pad is stranded"
        )
        #expect(open.islands.count == 2)
        let flyline = try #require(open.flylines.first)
        #expect(flyline.length == 0, "the pad still overlaps the wire in plan view")

        let restored = try harness.applyAndVerify(
            LayoutEditDelta(addedVias: [viaB]),
            context: "re-add via B"
        )
        #expect(!restored.analysis.opens.contains { $0.netID == fixture.netB })
    }

    @Test func addedViaCreatesShortAcrossLayersLive() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try LiveConnectivityEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        // An M2 pad on net B floating in plan view over net A's M1 wire:
        // no contact until a via lands there.
        let strayPad = LayoutShape(
            layer: fixture.m2,
            netID: fixture.netB,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 5.0, y: 0),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        let before = try harness.applyAndVerify(
            LayoutEditDelta(addedShapes: [strayPad]),
            context: "add stray pad over wire A"
        )
        #expect(
            !before.analysis.shorts.contains { Set($0.netIDs).isSuperset(of: [fixture.netA, fixture.netB]) },
            "plan-view overlap without a via must not short"
        )

        let bridgeVia = LayoutVia(
            viaDefinitionID: "VIA1",
            position: LayoutPoint(x: 5.2, y: 0.2),
            netID: nil
        )
        let shorted = try harness.applyAndVerify(
            LayoutEditDelta(addedVias: [bridgeVia]),
            context: "land a via on the stray pad"
        )
        #expect(
            shorted.analysis.shorts.contains { Set($0.netIDs).isSuperset(of: [fixture.netA, fixture.netB]) },
            "the via fuses wire A and the net-B pad into one conductor"
        )

        let cleared = try harness.applyAndVerify(
            LayoutEditDelta(removedViaIDs: [bridgeVia.id]),
            context: "remove the bridging via"
        )
        #expect(
            !cleared.analysis.shorts.contains { Set($0.netIDs).isSuperset(of: [fixture.netA, fixture.netB]) }
        )
    }

    @Test func bridgeShapeMergesOpenIslands() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try LiveConnectivityEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        // Two disjoint M1 stubs on a fresh net: an open with one flyline.
        let netC = UUID()
        let stubLeft = LayoutShape(
            layer: fixture.m1,
            netID: netC,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 4),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        let stubRight = LayoutShape(
            layer: fixture.m1,
            netID: netC,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 3, y: 4),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        let open = try harness.applyAndVerify(
            LayoutEditDelta(addedShapes: [stubLeft, stubRight]),
            context: "add disjoint net C stubs"
        )
        let openC = try #require(open.analysis.opens.first { $0.netID == netC })
        #expect(openC.islands.count == 2)
        #expect(abs((openC.flylines.first?.length ?? 0) - 2) < 1e-9)

        let bridge = LayoutShape(
            layer: fixture.m1,
            netID: nil,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.8, y: 4),
                size: LayoutSize(width: 2.4, height: 0.4)
            ))
        )
        let closed = try harness.applyAndVerify(
            LayoutEditDelta(addedShapes: [bridge]),
            context: "bridge the stubs"
        )
        #expect(
            !closed.analysis.opens.contains { $0.netID == netC },
            "the bridge fuses both stubs into one conductor piece"
        )
    }

    @Test func emptyDeltaIsExactNoOp() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try LiveConnectivityEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )
        let before = harness.session.currentAnalysis
        let update = try harness.applyAndVerify(LayoutEditDelta(), context: "empty delta")
        #expect(update.analysis == before)
        #expect(update.recomputedElementCount == 0)
        #expect(update.recomputedComponentCount == 0)
    }

    @Test func localityCountersStayBoundedForLocalEdit() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try LiveConnectivityEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )
        let total = harness.session.currentAnalysis.nets
            .reduce(0) { $0 + $1.shapeIDs.count + $1.viaIDs.count }

        // Nudging wire A re-partitions only net A's conductor piece, not
        // the whole design.
        var nudged = fixture.wireA
        nudged.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 0, y: 0.01),
            size: LayoutSize(width: 8, height: 0.4)
        ))
        let update = try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [nudged]),
            context: "nudge wire A"
        )
        #expect(update.recomputedElementCount < total, "a local edit must not re-derive every element")
        #expect(update.recomputedElementCount >= 3, "wire A's own conductor piece re-derives")
    }

    @Test func rebuildHandlesStructuralChange() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try LiveConnectivityEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        // Drop the second child instance — not expressible as a delta.
        var structural = harness.document
        guard let topIndex = structural.cells.firstIndex(where: { $0.id == structural.topCellID }) else {
            preconditionFailure("fixture document declares a top cell")
        }
        structural.cells[topIndex].instances.removeLast()
        try harness.rebuildAndVerify(
            document: structural,
            context: "remove one child instance"
        )
        #expect(
            harness.session.currentAnalysis.opens.isEmpty,
            "with one instance left, the child net is a single conductor piece"
        )
    }

    // MARK: - Validation

    @Test func unknownShapeUpdateIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try LiveConnectivitySession(document: fixture.document, tech: fixture.tech)
        let ghost = LayoutShape(
            layer: fixture.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        #expect(throws: LiveConnectivitySessionError.unknownShapeID(ghost.id)) {
            try session.apply(LayoutEditDelta(updatedShapes: [ghost]))
        }
    }

    @Test func duplicateShapeAddIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try LiveConnectivitySession(document: fixture.document, tech: fixture.tech)
        #expect(throws: LiveConnectivitySessionError.duplicateShapeID(fixture.wireA.id)) {
            try session.apply(LayoutEditDelta(addedShapes: [fixture.wireA]))
        }
    }

    @Test func conflictingDeltaEntryIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try LiveConnectivitySession(document: fixture.document, tech: fixture.tech)
        #expect(throws: LiveConnectivitySessionError.conflictingDeltaEntry(fixture.wireA.id)) {
            try session.apply(LayoutEditDelta(
                updatedShapes: [fixture.wireA],
                removedShapeIDs: [fixture.wireA.id]
            ))
        }
    }

    @Test func childIdentifierCollisionIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try LiveConnectivitySession(document: fixture.document, tech: fixture.tech)
        let colliding = LayoutShape(
            id: fixture.childShapeID,
            layer: fixture.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        #expect(throws: LiveConnectivitySessionError.hierarchyIdentifierCollision(fixture.childShapeID)) {
            try session.apply(LayoutEditDelta(addedShapes: [colliding]))
        }
    }

    @Test func missingTargetCellIsRejectedAtInit() {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let empty = LayoutDocument(name: "empty", cells: [], topCellID: nil)
        #expect(throws: LiveConnectivitySessionError.targetCellNotFound) {
            try LiveConnectivitySession(document: empty, tech: fixture.tech)
        }
    }

    // MARK: - Random delta generation

    private static func randomDelta(
        rng: inout SplitMix64,
        topShapes: [LayoutShape],
        topVias: [LayoutVia],
        fixture: IncrementalDRCEquivalenceHarness.RichFixture
    ) -> LayoutEditDelta {
        var delta = LayoutEditDelta()
        var usedShapeIDs: Set<UUID> = []
        var usedViaIDs: Set<UUID> = []

        if topShapes.count > 8, Double.random(in: 0..<1, using: &rng) < 0.35,
           let victim = topShapes.randomElement(using: &rng) {
            delta.removedShapeIDs.append(victim.id)
            usedShapeIDs.insert(victim.id)
        }
        if topVias.count > 2, Double.random(in: 0..<1, using: &rng) < 0.3,
           let victim = topVias.randomElement(using: &rng) {
            delta.removedViaIDs.append(victim.id)
            usedViaIDs.insert(victim.id)
        }

        for _ in 0..<Int.random(in: 0...2, using: &rng) {
            guard let target = topShapes.randomElement(using: &rng),
                  usedShapeIDs.insert(target.id).inserted else { continue }
            var updated = target
            let roll = Double.random(in: 0..<1, using: &rng)
            if roll < 0.6 {
                updated.geometry = .rect(randomRect(rng: &rng))
            } else if roll < 0.7, updated.layer == fixture.m1 || updated.layer == fixture.m2 {
                updated.layer = updated.layer == fixture.m1 ? fixture.m2 : fixture.m1
            } else {
                updated.netID = randomNet(rng: &rng, fixture: fixture)
            }
            delta.updatedShapes.append(updated)
        }
        if let target = topVias.randomElement(using: &rng),
           Double.random(in: 0..<1, using: &rng) < 0.45,
           usedViaIDs.insert(target.id).inserted {
            var updated = target
            if Double.random(in: 0..<1, using: &rng) < 0.7 {
                updated.position = randomPoint(rng: &rng)
            } else {
                updated.netID = randomNet(rng: &rng, fixture: fixture)
            }
            delta.updatedVias.append(updated)
        }

        if topShapes.count < 60 {
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                let layer = Double.random(in: 0..<1, using: &rng) < 0.55 ? fixture.m1 : fixture.m2
                delta.addedShapes.append(LayoutShape(
                    layer: layer,
                    netID: randomNet(rng: &rng, fixture: fixture),
                    geometry: .rect(randomRect(rng: &rng))
                ))
            }
        }
        if topVias.count < 20, Double.random(in: 0..<1, using: &rng) < 0.45 {
            delta.addedVias.append(LayoutVia(
                viaDefinitionID: "VIA1",
                position: randomPoint(rng: &rng),
                netID: randomNet(rng: &rng, fixture: fixture)
            ))
        }
        return delta
    }

    private static func randomRect(rng: inout SplitMix64) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(
                x: Double.random(in: 0..<7, using: &rng),
                y: Double.random(in: 0..<7, using: &rng)
            ),
            size: LayoutSize(
                width: Double.random(in: 0.3..<1.6, using: &rng),
                height: Double.random(in: 0.3..<1.6, using: &rng)
            )
        )
    }

    private static func randomPoint(rng: inout SplitMix64) -> LayoutPoint {
        LayoutPoint(
            x: Double.random(in: 0..<8, using: &rng),
            y: Double.random(in: 0..<8, using: &rng)
        )
    }

    private static func randomNet(
        rng: inout SplitMix64,
        fixture: IncrementalDRCEquivalenceHarness.RichFixture
    ) -> UUID? {
        if Double.random(in: 0..<1, using: &rng) < 0.2 { return nil }
        return fixture.netPool.randomElement(using: &rng)
    }
}
