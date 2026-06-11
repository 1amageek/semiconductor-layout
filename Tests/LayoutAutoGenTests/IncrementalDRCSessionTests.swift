import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Equivalence contract of `IncrementalDRCSession`: after any sequence of
/// geometry deltas, the live snapshot must equal a from-scratch
/// `LayoutDRCService.run` on the identically edited document — exactly,
/// as a canonical violation multiset — except the explicitly declared
/// stale antenna tier, which `commit()` must close.
@Suite("IncrementalDRCSession Equivalence", .timeLimit(.minutes(5)))
struct IncrementalDRCSessionTests {

    // MARK: - Randomized property test

    @Test func randomizedEditSequenceMatchesFullRun() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )
        let seed: UInt64 = 0x1A2B_3C4D_5E6F_0001
        var rng = SplitMix64(seed: seed)

        for step in 0..<60 {
            let delta = Self.randomDelta(
                rng: &rng,
                topShapes: harness.topShapes,
                topVias: harness.topVias,
                fixture: fixture
            )
            try harness.applyAndVerify(delta, context: "seed \(seed) step \(step)")
            if step % 10 == 9 {
                harness.verifyCommit(context: "seed \(seed) commit after step \(step)")
            }
        }
    }

    // MARK: - Deterministic scenarios

    @Test func netReassignmentSplitsConnectivity() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        var moved = fixture.wireA
        moved.netID = fixture.netB
        let update = try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [moved]),
            context: "reassign wire A onto net B"
        )

        let opensOnNetB = update.result.violations.filter {
            $0.kind == .disconnectedOpen && $0.netIDs == [fixture.netB]
        }
        #expect(
            !opensOnNetB.isEmpty,
            "wire A is disjoint from net B's stack, so net B must report an open"
        )
        #expect(Set(update.recomputedLayers).contains(fixture.m1))
        #expect(update.recomputedNetCount == 2, "old and new nets must both re-verify")
    }

    @Test func viaMoveBreaksAndRestoresEnclosure() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        var nudged = fixture.viaB
        nudged.position = LayoutPoint(x: nudged.position.x, y: nudged.position.y + 0.06)
        let broken = try harness.applyAndVerify(
            LayoutEditDelta(updatedVias: [nudged]),
            context: "via B moved past its enclosure margin"
        )
        #expect(
            broken.result.violations.contains { $0.viaIDs.contains(fixture.viaB.id) },
            "a 0.06um offset against a 0.05um margin must flag via B"
        )
        #expect(
            broken.recomputedLayers.isEmpty,
            "a via-only edit must not re-verify any shape layer"
        )
        #expect(broken.recomputedViaCount == 1)

        let restored = try harness.applyAndVerify(
            LayoutEditDelta(updatedVias: [fixture.viaB]),
            context: "via B moved back"
        )
        #expect(
            !restored.result.violations.contains { $0.viaIDs.contains(fixture.viaB.id) },
            "restoring the via must clear its enclosure violation"
        )
    }

    @Test func boundingBoxGrowthReverifiesDensityEverywhere() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        // Moving the wire far right grows the overall bounding box, which
        // shifts every layer's density windows; equivalence holds only if
        // the session re-verifies density beyond the edited layer.
        var stretched = fixture.wireA
        stretched.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 12, y: 0),
            size: LayoutSize(width: 8, height: 0.4)
        ))
        try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [stretched]),
            context: "wire A relocated outside the previous bounding box"
        )
        try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [fixture.wireA]),
            context: "wire A restored, shrinking the bounding box back"
        )
    }

    @Test func emptyDeltaKeepsSnapshotIdentical() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )
        let before = IncrementalDRCEquivalenceHarness.canonicalCounts(
            harness.session.currentResult.violations,
            excludingAntenna: false
        )
        let update = try harness.applyAndVerify(LayoutEditDelta(), context: "empty delta")
        let after = IncrementalDRCEquivalenceHarness.canonicalCounts(
            update.result.violations,
            excludingAntenna: false
        )
        #expect(before == after, "an empty delta must not change any violation")
        #expect(update.recomputedLayers.isEmpty)
        #expect(update.recomputedViaCount == 0)
        #expect(update.recomputedNetCount == 0)
    }

    @Test func antennaStalenessIsReportedAndCommitClosesIt() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )
        #expect(harness.session.staleKinds.isEmpty, "a fresh session is fully verified")

        var widened = fixture.padB
        widened.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 3.3, y: 1.5),
            size: LayoutSize(width: 0.5, height: 0.4)
        ))
        let update = try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [widened]),
            context: "pad B widened"
        )
        #expect(update.staleKinds == [.antenna])
        #expect(harness.session.staleKinds == [.antenna])

        harness.verifyCommit(context: "commit after pad widening")
        #expect(harness.session.staleKinds.isEmpty)
    }

    @Test func rebuildHandlesStructuralChange() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        // Structural change a delta cannot express: a third child instance.
        var document = harness.document
        guard let topIndex = document.cells.firstIndex(where: { $0.id == document.topCellID }),
              let childCellID = document.cells[topIndex].instances.first?.cellID else {
            Issue.record("fixture must expose a top cell with instances")
            return
        }
        document.cells[topIndex].instances.append(LayoutInstance(
            cellID: childCellID,
            name: "u3",
            transform: LayoutTransform(translation: LayoutPoint(x: 1.0, y: 5.0))
        ))
        try harness.rebuildAndVerify(
            document: document,
            context: "rebuild after adding instance u3"
        )

        // The rebuilt session must keep verifying deltas correctly.
        var moved = fixture.padB
        moved.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 3.3, y: 1.52),
            size: LayoutSize(width: 0.4, height: 0.4)
        ))
        try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [moved]),
            context: "delta after rebuild"
        )
    }

    @Test func unruledLayerTripsCoverageIncrementally() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        let stray = LayoutShape(
            layer: fixture.m3,
            netID: fixture.netPool[2],
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1, y: 4),
                size: LayoutSize(width: 0.5, height: 0.5)
            ))
        )
        let added = try harness.applyAndVerify(
            LayoutEditDelta(addedShapes: [stray]),
            context: "shape added on unruled layer M3"
        )
        #expect(
            added.result.violations.contains {
                $0.kind == .ruleCoverage && $0.layer == fixture.m3
            },
            "geometry on a layer without rules must flag rule coverage"
        )

        let removed = try harness.applyAndVerify(
            LayoutEditDelta(removedShapeIDs: [stray.id]),
            context: "stray M3 shape removed"
        )
        #expect(
            !removed.result.violations.contains { $0.layer == fixture.m3 },
            "removing the only M3 shape must clear its coverage violation"
        )
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
        if topVias.count > 2, Double.random(in: 0..<1, using: &rng) < 0.25,
           let victim = topVias.randomElement(using: &rng) {
            delta.removedViaIDs.append(victim.id)
            usedViaIDs.insert(victim.id)
        }

        for _ in 0..<Int.random(in: 0...2, using: &rng) {
            guard let target = topShapes.randomElement(using: &rng),
                  usedShapeIDs.insert(target.id).inserted else { continue }
            var updated = target
            let roll = Double.random(in: 0..<1, using: &rng)
            if roll < 0.65 {
                updated.geometry = .rect(randomRect(rng: &rng))
            } else if roll < 0.75, updated.layer == fixture.m1 || updated.layer == fixture.m2 {
                updated.layer = updated.layer == fixture.m1 ? fixture.m2 : fixture.m1
            } else {
                updated.netID = randomNet(rng: &rng, fixture: fixture)
            }
            delta.updatedShapes.append(updated)
        }
        if let target = topVias.randomElement(using: &rng),
           Double.random(in: 0..<1, using: &rng) < 0.4,
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
                delta.addedShapes.append(randomShape(rng: &rng, fixture: fixture))
            }
        }
        if topVias.count < 20, Double.random(in: 0..<1, using: &rng) < 0.4 {
            delta.addedVias.append(LayoutVia(
                viaDefinitionID: "VIA1",
                position: randomPoint(rng: &rng),
                netID: randomNet(rng: &rng, fixture: fixture)
            ))
        }
        return delta
    }

    private static func randomShape(
        rng: inout SplitMix64,
        fixture: IncrementalDRCEquivalenceHarness.RichFixture
    ) -> LayoutShape {
        let roll = Double.random(in: 0..<1, using: &rng)
        let layer: LayoutLayerID
        if roll < 0.45 {
            layer = fixture.m1
        } else if roll < 0.85 {
            layer = fixture.m2
        } else if roll < 0.95 {
            layer = fixture.m3
        } else {
            layer = fixture.mark
        }
        return LayoutShape(
            layer: layer,
            netID: randomNet(rng: &rng, fixture: fixture),
            geometry: .rect(randomRect(rng: &rng))
        )
    }

    private static func randomRect(rng: inout SplitMix64) -> LayoutRect {
        LayoutRect(
            origin: randomPoint(rng: &rng),
            size: LayoutSize(
                width: snapped(Double.random(in: 0.08..<1.6, using: &rng)),
                height: snapped(Double.random(in: 0.08..<1.6, using: &rng))
            )
        )
    }

    private static func randomPoint(rng: inout SplitMix64) -> LayoutPoint {
        LayoutPoint(
            x: snapped(Double.random(in: 0..<9, using: &rng)),
            y: snapped(Double.random(in: 0..<9, using: &rng))
        )
    }

    private static func randomNet(
        rng: inout SplitMix64,
        fixture: IncrementalDRCEquivalenceHarness.RichFixture
    ) -> UUID? {
        if Double.random(in: 0..<1, using: &rng) < 0.15 { return nil }
        return fixture.netPool.randomElement(using: &rng)
    }

    private static func snapped(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
