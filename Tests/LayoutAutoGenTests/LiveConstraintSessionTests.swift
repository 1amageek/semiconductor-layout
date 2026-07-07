import Foundation
import Testing
import LayoutCore
import LayoutVerify

@Suite("LiveConstraintSession", .timeLimit(.minutes(1)))
struct LiveConstraintSessionTests {
    private static let layer = LayoutLayerID(name: "M1", purpose: "drawing")

    private struct Projection: Equatable {
        var kind: LayoutConstraintViolationKind
        var constraintIndex: Int
        var severity: LayoutViolationSeverity
        var message: String
        var region: LayoutRect
        var memberIDs: [UUID]
        var measured: Double?
        var required: Double?
    }

    @Test func editedMemberRecomputesOnlyReferencingConstraint() throws {
        let fixture = Self.fixture()
        var document = fixture.document
        let session = try LiveConstraintSession(document: document, cellID: fixture.cellID)

        var healedB = fixture.b
        healedB.geometry = .rect(Self.rect(10, 0, 1, 1))
        let delta = LayoutEditDelta(updatedShapes: [healedB])
        try Self.applyDelta(delta, to: &document, cellID: fixture.cellID)

        let update = try session.apply(delta)
        let reference = try LayoutConstraintChecker().check(document: document, cellID: fixture.cellID)

        #expect(update.recomputedConstraintIndices == [0])
        #expect(update.skippedConstraintCount == 1)
        #expect(Self.project(update.violations) == Self.project(reference))
    }

    @Test func unreferencedEditSkipsAllConstraintsWithoutChangingVerdict() throws {
        let fixture = Self.fixture()
        var document = fixture.document
        let session = try LiveConstraintSession(document: document, cellID: fixture.cellID)
        let before = session.currentViolations

        let unrelated = Self.shape(100, 100, 1, 1)
        let delta = LayoutEditDelta(addedShapes: [unrelated])
        try Self.applyDelta(delta, to: &document, cellID: fixture.cellID)

        let update = try session.apply(delta)
        let reference = try LayoutConstraintChecker().check(document: document, cellID: fixture.cellID)

        #expect(update.recomputedConstraintIndices.isEmpty)
        #expect(update.skippedConstraintCount == 2)
        #expect(Self.project(update.violations) == Self.project(before))
        #expect(Self.project(update.violations) == Self.project(reference))
    }

    @Test func removedReferencedMemberProducesSameUnresolvedViolationAsBatch() throws {
        let fixture = Self.fixture()
        var document = fixture.document
        let session = try LiveConstraintSession(document: document, cellID: fixture.cellID)

        let delta = LayoutEditDelta(removedShapeIDs: [fixture.c.id])
        try Self.applyDelta(delta, to: &document, cellID: fixture.cellID)

        let update = try session.apply(delta)
        let reference = try LayoutConstraintChecker().check(document: document, cellID: fixture.cellID)

        #expect(update.recomputedConstraintIndices == [1])
        #expect(update.skippedConstraintCount == 1)
        #expect(Self.project(update.violations) == Self.project(reference))
        #expect(update.violations.contains { $0.kind == .unresolvedMember && $0.constraintIndex == 1 })
    }

    @Test func duplicateShapeAddIsRejectedBeforeOverlayMutation() throws {
        let fixture = Self.fixture()
        let session = try LiveConstraintSession(document: fixture.document, cellID: fixture.cellID)
        let before = session.currentViolations

        #expect(throws: LayoutEditDeltaValidationError.duplicateShapeID(fixture.a.id)) {
            try session.apply(LayoutEditDelta(addedShapes: [fixture.a]))
        }
        #expect(Self.project(session.currentViolations) == Self.project(before))
    }

    @Test func conflictingShapeDeltaEntryIsRejectedBeforeOverlayMutation() throws {
        let fixture = Self.fixture()
        let session = try LiveConstraintSession(document: fixture.document, cellID: fixture.cellID)
        let before = session.currentViolations

        #expect(throws: LayoutEditDeltaValidationError.conflictingDeltaEntry(fixture.a.id)) {
            try session.apply(LayoutEditDelta(
                updatedShapes: [fixture.a],
                removedShapeIDs: [fixture.a.id]
            ))
        }
        #expect(Self.project(session.currentViolations) == Self.project(before))
    }

    @Test func checkerSubsetPreservesOriginalConstraintIndices() throws {
        let fixture = Self.fixture()
        let partial = try LayoutConstraintChecker().check(
            document: fixture.document,
            cellID: fixture.cellID,
            constraintIndices: [1]
        )
        let full = try LayoutConstraintChecker().check(document: fixture.document, cellID: fixture.cellID)
            .filter { $0.constraintIndex == 1 }

        #expect(Self.project(partial) == Self.project(full))
    }

    private static func fixture() -> (
        document: LayoutDocument,
        cellID: UUID,
        a: LayoutShape,
        b: LayoutShape,
        c: LayoutShape,
        d: LayoutShape
    ) {
        let a = shape(0, 0, 1, 1)
        let b = shape(10, 10, 1, 1)
        let c = shape(20, 0, 1, 1)
        let d = shape(30, 0, 2, 1)
        let constraints: [LayoutConstraint] = [
            .alignment(LayoutAlignmentConstraint(mode: .minY, members: [a.id, b.id])),
            .matching(LayoutMatchingConstraint(members: [c.id, d.id])),
        ]
        let cell = LayoutCell(name: "TOP", shapes: [a, b, c, d], constraints: constraints)
        let document = LayoutDocument(name: "constraints", cells: [cell], topCellID: cell.id)
        return (document, cell.id, a, b, c, d)
    }

    private static func shape(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayoutShape {
        LayoutShape(layer: layer, geometry: .rect(rect(x, y, width, height)))
    }

    private static func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: x, y: y),
            size: LayoutSize(width: width, height: height)
        )
    }

    private static func project(_ violations: [LayoutConstraintViolation]) -> [Projection] {
        violations.map {
            Projection(
                kind: $0.kind,
                constraintIndex: $0.constraintIndex,
                severity: $0.severity,
                message: $0.message,
                region: $0.region,
                memberIDs: $0.memberIDs,
                measured: $0.measured,
                required: $0.required
            )
        }
    }

    private static func applyDelta(
        _ delta: LayoutEditDelta,
        to document: inout LayoutDocument,
        cellID: UUID
    ) throws {
        guard var cell = document.cell(withID: cellID) else {
            throw LayoutCoreError.cellNotFound(cellID)
        }
        for shape in delta.updatedShapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                throw LayoutCoreError.shapeNotFound(shape.id)
            }
            cell.shapes[index] = shape
        }
        for id in delta.removedShapeIDs {
            guard let index = cell.shapes.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.shapeNotFound(id)
            }
            cell.shapes.remove(at: index)
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
        document.updateCell(cell)
    }
}
