import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutEditor

/// Contract of the M5 live constraint layer: constraints persisted on the
/// active cell are re-evaluated through the same commitDelta stream as
/// DRC and connectivity, so after every discrete edit, every mid-gesture
/// transient tick, every undo/redo, and every constraint CRUD the
/// published `constraintViolations` must equal a from-scratch
/// `LayoutConstraintChecker` run (ignoring violation identities).
@MainActor
@Suite("LayoutEditorViewModel live constraints", .timeLimit(.minutes(5)))
struct LayoutEditorViewModelConstraintTests {

    private struct Fixture {
        var viewModel: LayoutEditorViewModel
        var rich: IncrementalDRCEquivalenceHarness.RichFixture
        /// M2 pad on net A at (0.3, 0)–(0.7, 0.4).
        var padA: LayoutShape
        /// M2 pad on net B at (3.3, 1.5)–(3.7, 1.9).
        var padB: LayoutShape
    }

    private static func makeFixture() throws -> Fixture {
        let rich = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let viewModel = LayoutEditorViewModel(document: rich.document, tech: rich.tech)
        let shapes = viewModel.documentShapes()
        return Fixture(
            viewModel: viewModel,
            rich: rich,
            padA: try #require(shapes.first { $0.layer == rich.m2 && $0.netID == rich.netA }),
            padB: rich.padB
        )
    }

    // MARK: - Oracle

    /// Everything the checker reports except the per-run violation `id`.
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

    private func project(_ violations: [LayoutConstraintViolation]) -> [Projection] {
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

    /// The live verdict must equal a from-scratch batch check, field for
    /// field, in the checker's deterministic order.
    private func expectMatchesBatch(
        _ viewModel: LayoutEditorViewModel,
        _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let cellID = try #require(viewModel.activeCellID, sourceLocation: sourceLocation)
        let reference = try LayoutConstraintChecker()
            .check(document: viewModel.editor.document, cellID: cellID)
        #expect(
            project(viewModel.constraintViolations) == project(reference),
            "\(context): live constraint verdict must equal a from-scratch check",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - CRUD with undo

    @Test func addRemoveConstraintEvaluatesLiveAndUndoes() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel
        #expect(viewModel.constraintViolations.isEmpty)
        #expect(viewModel.activeCellConstraints.isEmpty)

        // Pads A and B share minX? No — a satisfied constraint first:
        // both pads share a 0.4 × 0.4 bounding box, so matching passes.
        viewModel.addConstraint(.matching(LayoutMatchingConstraint(
            members: [fixture.padA.id, fixture.padB.id]
        )))
        #expect(viewModel.activeCellConstraints.count == 1)
        #expect(viewModel.constraintViolations.isEmpty)
        try expectMatchesBatch(viewModel, "after satisfied add")

        // A broken constraint surfaces immediately: the pads' minY differ
        // by exactly 1.5.
        viewModel.addConstraint(.alignment(LayoutAlignmentConstraint(
            mode: .minY,
            members: [fixture.padA.id, fixture.padB.id]
        )))
        #expect(viewModel.activeCellConstraints.count == 2)
        let violation = try #require(viewModel.constraintViolations.first)
        #expect(viewModel.constraintViolations.count == 1)
        #expect(violation.kind == .alignmentMismatch)
        #expect(violation.constraintIndex == 1)
        #expect(violation.measured == 1.5)
        try expectMatchesBatch(viewModel, "after broken add")

        // Each add is one undo step; undo removes both the constraint and
        // its verdict, redo brings them back.
        viewModel.undo()
        #expect(viewModel.activeCellConstraints.count == 1)
        #expect(viewModel.constraintViolations.isEmpty)
        try expectMatchesBatch(viewModel, "after undo")
        viewModel.redo()
        #expect(viewModel.activeCellConstraints.count == 2)
        #expect(viewModel.constraintViolations.count == 1)
        try expectMatchesBatch(viewModel, "after redo")

        // Explicit removal: dropping the broken alignment clears the
        // verdict; an out-of-range index is a no-op.
        viewModel.removeConstraint(at: 1)
        #expect(viewModel.activeCellConstraints.count == 1)
        #expect(viewModel.constraintViolations.isEmpty)
        viewModel.removeConstraint(at: 5)
        #expect(viewModel.activeCellConstraints.count == 1)
        try expectMatchesBatch(viewModel, "after remove")
    }

    // MARK: - Edit verbs break and heal constraints live

    @Test func discreteMoveBreaksAndHealsTheConstraint() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        // Matching on the two equal pads is satisfied; an alignment on
        // their minY is broken until pad A moves up by 1.5.
        viewModel.addConstraint(.alignment(LayoutAlignmentConstraint(
            mode: .minY,
            members: [fixture.padA.id, fixture.padB.id]
        )))
        #expect(viewModel.constraintViolations.count == 1)

        viewModel.selectedShapeIDs = [fixture.padA.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: 0, y: 1.5))
        #expect(
            viewModel.constraintViolations.isEmpty,
            "moving pad A onto pad B's row heals the alignment live"
        )
        try expectMatchesBatch(viewModel, "after healing move")

        // Moving away again re-breaks it, with the measured gap tracking
        // the geometry.
        viewModel.moveSelectedShapes(by: LayoutPoint(x: 0, y: -0.5))
        let reBroken = try #require(viewModel.constraintViolations.first)
        #expect(reBroken.kind == .alignmentMismatch)
        #expect(abs((reBroken.measured ?? 0) - 0.5) <= 1e-12)
        try expectMatchesBatch(viewModel, "after re-breaking move")

        // Undo restores the healed state, then the broken origin state.
        viewModel.undo()
        #expect(viewModel.constraintViolations.isEmpty)
        try expectMatchesBatch(viewModel, "after undo to healed")
        viewModel.undo()
        #expect(viewModel.constraintViolations.count == 1)
        try expectMatchesBatch(viewModel, "after undo to origin")
    }

    @Test func transientDragTicksUpdateTheVerdictMidGesture() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        viewModel.addConstraint(.alignment(LayoutAlignmentConstraint(
            mode: .minY,
            members: [fixture.padA.id, fixture.padB.id]
        )))
        #expect(viewModel.constraintViolations.count == 1)

        // Mid-gesture: every tick re-evaluates against the transient
        // geometry — the verdict heals while the pointer is still down.
        viewModel.selectedShapeIDs = [fixture.padA.id]
        viewModel.beginShapeDrag()
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0, y: 1.5))
        #expect(
            viewModel.constraintViolations.isEmpty,
            "the constraint verdict must track the gesture live"
        )
        try expectMatchesBatch(viewModel, "mid-drag healed")

        viewModel.updateShapeDrag(to: LayoutPoint(x: 0, y: 1.0))
        let midDrag = try #require(viewModel.constraintViolations.first)
        #expect(abs((midDrag.measured ?? 0) - 0.5) <= 1e-12)
        try expectMatchesBatch(viewModel, "mid-drag re-broken")

        // Cancel restores the origin geometry and the origin verdict.
        viewModel.cancelShapeDrag()
        let restored = try #require(viewModel.constraintViolations.first)
        #expect(restored.measured == 1.5)
        try expectMatchesBatch(viewModel, "after cancel")

        // A completed gesture keeps the healed verdict.
        viewModel.beginShapeDrag()
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0, y: 1.5))
        viewModel.endShapeDrag()
        #expect(viewModel.constraintViolations.isEmpty)
        try expectMatchesBatch(viewModel, "after end")
    }

    @Test func deletingAMemberReportsItUnresolvedInsteadOfClean() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        viewModel.addConstraint(.matching(LayoutMatchingConstraint(
            members: [fixture.padA.id, fixture.padB.id]
        )))
        #expect(viewModel.constraintViolations.isEmpty)

        viewModel.selectedShapeIDs = [fixture.padA.id]
        viewModel.deleteSelectedShapes()
        let violation = try #require(viewModel.constraintViolations.first)
        #expect(
            violation.kind == .unresolvedMember,
            "a deleted member must be reported, never silently dropped"
        )
        #expect(violation.memberIDs == [fixture.padA.id])
        try expectMatchesBatch(viewModel, "after delete")

        viewModel.undo()
        #expect(viewModel.constraintViolations.isEmpty)
        try expectMatchesBatch(viewModel, "after undo")
    }

    // MARK: - Persistence

    @Test func constraintsAndVerdictSurviveAJSONRoundTrip() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        viewModel.addConstraint(.matching(LayoutMatchingConstraint(
            members: [fixture.padA.id, fixture.padB.id]
        )))
        viewModel.addConstraint(.alignment(LayoutAlignmentConstraint(
            mode: .minY,
            members: [fixture.padA.id, fixture.padB.id]
        )))
        let savedVerdict = project(viewModel.constraintViolations)
        #expect(savedVerdict.count == 1)

        let data = try JSONEncoder().encode(viewModel.editor.document)
        let decoded = try JSONDecoder().decode(LayoutDocument.self, from: data)

        // A fresh editor over the reloaded document re-derives the same
        // constraints and the same verdict at init.
        let reloaded = LayoutEditorViewModel(document: decoded, tech: fixture.rich.tech)
        #expect(reloaded.activeCellConstraints == viewModel.activeCellConstraints)
        #expect(project(reloaded.constraintViolations) == savedVerdict)
        try expectMatchesBatch(reloaded, "after JSON round trip")
    }
}
