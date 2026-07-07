import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Input-rejection contract of `IncrementalDRCSession`: every malformed
/// delta or document fails with a typed error and leaves the session
/// state untouched — never absorbed into a wrong snapshot.
@Suite("IncrementalDRCSession Validation", .timeLimit(.minutes(2)))
struct IncrementalDRCSessionValidationTests {

    @Test func missingTopCellIsRejected() {
        let document = LayoutDocument(name: "empty", cells: [], topCellID: nil)
        #expect(throws: IncrementalDRCSessionError.targetCellNotFound) {
            _ = try IncrementalDRCSession(
                document: document,
                tech: IncrementalDRCEquivalenceHarness.makeRichFixture().tech
            )
        }
    }

    @Test func topLevelIDCollidingWithChildIsRejectedAtInit() {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        var document = fixture.document
        guard let topIndex = document.cells.firstIndex(where: { $0.id == document.topCellID }) else {
            Issue.record("fixture must declare a top cell")
            return
        }
        document.cells[topIndex].shapes.append(LayoutShape(
            id: fixture.childShapeID,
            layer: fixture.m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 9, y: 9),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        ))
        #expect(throws: IncrementalDRCSessionError.hierarchyIdentifierCollision(fixture.childShapeID)) {
            _ = try IncrementalDRCSession(document: document, tech: fixture.tech)
        }
    }

    @Test func duplicateTopShapeIDsAreRejectedAtInit() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        var document = fixture.document
        let topIndex = try #require(document.cells.firstIndex(where: { $0.id == document.topCellID }))
        var duplicate = fixture.wireA
        duplicate.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 12, y: 12),
            size: LayoutSize(width: 0.4, height: 0.4)
        ))
        document.cells[topIndex].shapes.append(duplicate)

        #expect(throws: IncrementalDRCSessionError.duplicateShapeID(fixture.wireA.id)) {
            _ = try IncrementalDRCSession(document: document, tech: fixture.tech)
        }
    }

    @Test func duplicateTopViaIDsAreRejectedAtInit() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        var document = fixture.document
        let topIndex = try #require(document.cells.firstIndex(where: { $0.id == document.topCellID }))
        var duplicate = fixture.viaB
        duplicate.position = LayoutPoint(x: 12, y: 12)
        document.cells[topIndex].vias.append(duplicate)

        #expect(throws: IncrementalDRCSessionError.duplicateViaID(fixture.viaB.id)) {
            _ = try IncrementalDRCSession(document: document, tech: fixture.tech)
        }
    }

    @Test func unknownShapeUpdateIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try IncrementalDRCSession(document: fixture.document, tech: fixture.tech)
        let ghost = LayoutShape(
            layer: fixture.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        #expect(throws: IncrementalDRCSessionError.unknownShapeID(ghost.id)) {
            _ = try session.apply(LayoutEditDelta(updatedShapes: [ghost]))
        }
    }

    @Test func unknownViaRemovalIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try IncrementalDRCSession(document: fixture.document, tech: fixture.tech)
        let ghostID = UUID()
        #expect(throws: IncrementalDRCSessionError.unknownViaID(ghostID)) {
            _ = try session.apply(LayoutEditDelta(removedViaIDs: [ghostID]))
        }
    }

    @Test func duplicateShapeAddIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try IncrementalDRCSession(document: fixture.document, tech: fixture.tech)
        let clone = LayoutShape(
            id: fixture.wireA.id,
            layer: fixture.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        #expect(throws: IncrementalDRCSessionError.duplicateShapeID(fixture.wireA.id)) {
            _ = try session.apply(LayoutEditDelta(addedShapes: [clone]))
        }
    }

    @Test func duplicateViaAddIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try IncrementalDRCSession(document: fixture.document, tech: fixture.tech)
        var clone = fixture.viaB
        clone.position = LayoutPoint(x: 12, y: 12)

        #expect(throws: IncrementalDRCSessionError.duplicateViaID(fixture.viaB.id)) {
            _ = try session.apply(LayoutEditDelta(addedVias: [clone]))
        }
    }

    @Test func conflictingDeltaEntryIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try IncrementalDRCSession(document: fixture.document, tech: fixture.tech)
        let delta = LayoutEditDelta(
            updatedShapes: [fixture.wireA],
            removedShapeIDs: [fixture.wireA.id]
        )
        #expect(throws: IncrementalDRCSessionError.conflictingDeltaEntry(fixture.wireA.id)) {
            _ = try session.apply(delta)
        }
    }

    @Test func addCollidingWithChildIDIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try IncrementalDRCSession(document: fixture.document, tech: fixture.tech)
        let collider = LayoutShape(
            id: fixture.childShapeID,
            layer: fixture.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        #expect(throws: IncrementalDRCSessionError.hierarchyIdentifierCollision(fixture.childShapeID)) {
            _ = try session.apply(LayoutEditDelta(addedShapes: [collider]))
        }
    }

    @Test func addViaCollidingWithChildIDIsRejected() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let session = try IncrementalDRCSession(document: fixture.document, tech: fixture.tech)
        let topID = try #require(fixture.document.topCellID)
        let childVia = try #require(
            fixture.document.cells.first { $0.id != topID }?.vias.first
        )
        let collider = LayoutVia(
            id: childVia.id,
            viaDefinitionID: childVia.viaDefinitionID,
            position: LayoutPoint(x: 12, y: 12),
            netID: fixture.netA
        )

        #expect(throws: IncrementalDRCSessionError.hierarchyIdentifierCollision(childVia.id)) {
            _ = try session.apply(LayoutEditDelta(addedVias: [collider]))
        }
    }

    @Test func rejectedDeltaLeavesSessionUsable() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )

        // Validation happens before any mutation, so a rejected delta must
        // not corrupt the session.
        let ghost = LayoutShape(
            layer: fixture.m2,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        #expect(throws: IncrementalDRCSessionError.unknownShapeID(ghost.id)) {
            _ = try harness.session.apply(LayoutEditDelta(updatedShapes: [ghost]))
        }

        var moved = fixture.padB
        moved.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 3.3, y: 1.52),
            size: LayoutSize(width: 0.4, height: 0.4)
        ))
        try harness.applyAndVerify(
            LayoutEditDelta(updatedShapes: [moved]),
            context: "valid delta after a rejected one"
        )
    }

    @Test func failedRebuildLeavesSessionUsable() throws {
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let harness = try IncrementalDRCEquivalenceHarness(
            document: fixture.document,
            tech: fixture.tech
        )
        let removable = try #require(harness.topShapes.dropFirst().first)
        var invalid = harness.document
        let topIndex = try #require(invalid.cells.firstIndex(where: { $0.id == invalid.topCellID }))
        invalid.cells[topIndex].shapes = [
            LayoutShape(
                id: fixture.childShapeID,
                layer: fixture.m1,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 10, y: 10),
                    size: LayoutSize(width: 0.4, height: 0.4)
                ))
            )
        ]

        #expect(throws: IncrementalDRCSessionError.hierarchyIdentifierCollision(fixture.childShapeID)) {
            _ = try harness.session.rebuild(document: invalid)
        }

        try harness.applyAndVerify(
            LayoutEditDelta(removedShapeIDs: [removable.id]),
            context: "valid delta after a failed rebuild"
        )
    }
}
