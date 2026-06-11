import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutEditor

/// Contract of the view model's live-DRC plumbing: after every editing
/// operation the published `violations` must equal a from-scratch batch
/// run on the edited document, shape identity survives moves, an
/// interactive drag collapses into one undo step, and enforce mode
/// constrains drags through the document mirror.
@MainActor
@Suite("LayoutEditorViewModel live DRC", .timeLimit(.minutes(5)))
struct LayoutEditorViewModelLiveDRCTests {

    private struct Fixture {
        var viewModel: LayoutEditorViewModel
        var m1: LayoutLayerID
        var anchor: LayoutShape
        var rover: LayoutShape
    }

    /// Same geometry as the drag-session fixture: 1x0.4 anchor at the
    /// origin, 1x0.4 rover at x = 3, m1 minSpacing 0.23, grid 0.01.
    private static func makeFixture() -> Fixture {
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
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 3.0, y: 0),
                size: LayoutSize(width: 1.0, height: 0.4)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [anchor, rover])
        let document = LayoutDocument(name: "live-drc-fixture", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: tech)
        return Fixture(viewModel: viewModel, m1: m1, anchor: anchor, rover: rover)
    }

    private func expectLiveMatchesBatch(
        _ viewModel: LayoutEditorViewModel,
        _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let reference = LayoutDRCService().run(
            document: viewModel.editor.document,
            tech: viewModel.tech,
            cellID: viewModel.activeCellID
        )
        #expect(
            IncrementalDRCEquivalenceHarness.canonicalCounts(viewModel.violations, excludingAntenna: false)
                == IncrementalDRCEquivalenceHarness.canonicalCounts(reference.violations, excludingAntenna: false),
            "\(context): live violations must equal a from-scratch batch run",
            sourceLocation: sourceLocation
        )
        #expect(
            viewModel.staleViolationKinds.isEmpty,
            "\(context): discrete edits must leave no stale checks",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Live snapshot equivalence

    @Test func liveSnapshotMatchesBatchAfterEachOperation() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        expectLiveMatchesBatch(viewModel, "initial")

        // A 0.1-wide sliver trips minWidth and minArea.
        viewModel.addRectangle(
            from: LayoutPoint(x: 0, y: 2),
            to: LayoutPoint(x: 0.1, y: 2.4)
        )
        expectLiveMatchesBatch(viewModel, "addRectangle")
        #expect(viewModel.violations.contains { $0.kind == .minWidth })

        // Discrete move of the rover next to the anchor: observe mode
        // does not constrain, so the violation lands and is reported.
        viewModel.selectedShapeIDs = [fixture.rover.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: -1.9, y: 0))
        expectLiveMatchesBatch(viewModel, "moveSelectedShapes")
        #expect(viewModel.violations.contains { $0.kind == .minSpacing })

        let sliverID = try #require(
            viewModel.documentShapes().first {
                $0.id != fixture.anchor.id && $0.id != fixture.rover.id
            }?.id
        )
        viewModel.selectedShapeIDs = [sliverID]
        viewModel.deleteSelectedShapes()
        expectLiveMatchesBatch(viewModel, "deleteSelectedShapes")
        #expect(!viewModel.violations.contains { $0.kind == .minWidth })
    }

    @Test func booleanOperationsKeepLiveSnapshotExact() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.activeLayer = fixture.m1

        // Merge the rover with an overlapping new rectangle.
        viewModel.addRectangle(
            from: LayoutPoint(x: 3.5, y: 0),
            to: LayoutPoint(x: 4.5, y: 0.4)
        )
        let addedID = try #require(
            viewModel.documentShapes().first {
                $0.id != fixture.anchor.id && $0.id != fixture.rover.id
            }?.id
        )
        viewModel.selectedShapeIDs = [fixture.rover.id, addedID]
        viewModel.mergeSelectedShapes()
        expectLiveMatchesBatch(viewModel, "merge")
        #expect(viewModel.documentShapes().count == 2, "two rects merge into one polygon")
        #expect(viewModel.selectedShapeIDs.isEmpty)

        // Split the merged polygon vertically through its middle.
        viewModel.splitShapes(
            from: LayoutPoint(x: 3.75, y: -1),
            to: LayoutPoint(x: 3.75, y: 1)
        )
        expectLiveMatchesBatch(viewModel, "split")
        #expect(viewModel.documentShapes().count == 3)

        // Subtract a notch through the anchor, leaving two slivers with
        // an illegal 0.2 gap — the live snapshot must report it.
        viewModel.subtractFromShapes(cutRect: LayoutRect(
            origin: LayoutPoint(x: 0.4, y: -0.1),
            size: LayoutSize(width: 0.2, height: 0.6)
        ))
        expectLiveMatchesBatch(viewModel, "subtract")
        #expect(viewModel.violations.contains { $0.kind == .minSpacing })
    }

    @Test func structuralPinEditResyncsLiveSession() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.addPin(
            name: "A",
            at: LayoutPoint(x: 0.2, y: 0.2),
            size: LayoutSize(width: 0.1, height: 0.1)
        )
        expectLiveMatchesBatch(viewModel, "addPin")
    }

    // MARK: - Identity preservation

    @Test func movePreservesShapeIdentity() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.selectedShapeIDs = [fixture.rover.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: 0.5, y: 0.25))

        let moved = try #require(
            viewModel.documentShapes().first { $0.id == fixture.rover.id },
            "the moved shape must keep its identity"
        )
        guard case .rect(let rect) = moved.geometry else {
            Issue.record("a moved rect must stay a rect")
            return
        }
        #expect(abs(rect.origin.x - 3.5) < 1e-9)
        #expect(abs(rect.origin.y - 0.25) < 1e-9)
        #expect(viewModel.selectedShapeIDs == [fixture.rover.id], "selection survives the move")
    }

    // MARK: - Interactive drag

    @Test func interactiveDragIsOneUndoStep() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.selectedShapeIDs = [fixture.rover.id]
        #expect(!viewModel.canUndo)

        viewModel.beginShapeDrag()
        #expect(viewModel.isDraggingShapes)
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0.2, y: 0))
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0.5, y: 0))
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0.8, y: 0.1))
        viewModel.endShapeDrag()
        #expect(!viewModel.isDraggingShapes)

        let moved = try #require(viewModel.documentShapes().first { $0.id == fixture.rover.id })
        guard case .rect(let rect) = moved.geometry else {
            Issue.record("a dragged rect must stay a rect")
            return
        }
        #expect(abs(rect.origin.x - 3.8) < 1e-9)
        #expect(abs(rect.origin.y - 0.1) < 1e-9)
        expectLiveMatchesBatch(viewModel, "after drag")

        #expect(viewModel.canUndo)
        viewModel.undo()
        let restored = try #require(viewModel.documentShapes().first { $0.id == fixture.rover.id })
        guard case .rect(let restoredRect) = restored.geometry else {
            Issue.record("undo must restore the rect")
            return
        }
        #expect(abs(restoredRect.origin.x - 3.0) < 1e-9)
        #expect(abs(restoredRect.origin.y) < 1e-9)
        #expect(!viewModel.canUndo, "the whole drag must be exactly one undo step")
        expectLiveMatchesBatch(viewModel, "after undo")
    }

    @Test func enforceDragConstrainsToLegalPosition() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.drdMode = .enforce
        viewModel.selectedShapeIDs = [fixture.rover.id]

        viewModel.beginShapeDrag()
        viewModel.updateShapeDrag(to: LayoutPoint(x: -1.95, y: 0))
        #expect(viewModel.dragOutcome == .constrained)
        #expect(!viewModel.violations.contains { $0.kind == .minSpacing })

        // The document mirror must render the constrained position, not
        // the raw pointer position.
        let dragged = try #require(viewModel.documentShapes().first { $0.id == fixture.rover.id })
        guard case .rect(let rect) = dragged.geometry else {
            Issue.record("a dragged rect must stay a rect")
            return
        }
        #expect(abs(rect.origin.x - 1.23) < 1e-9)

        viewModel.endShapeDrag()
        #expect(viewModel.dragOutcome == nil)
        expectLiveMatchesBatch(viewModel, "after enforce drag")
    }

    @Test func cancelDragRestoresDocument() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.selectedShapeIDs = [fixture.rover.id]

        viewModel.beginShapeDrag()
        viewModel.updateShapeDrag(to: LayoutPoint(x: -1.9, y: 0))
        #expect(viewModel.violations.contains { $0.kind == .minSpacing })
        viewModel.cancelShapeDrag()
        #expect(!viewModel.isDraggingShapes)

        let restored = try #require(viewModel.documentShapes().first { $0.id == fixture.rover.id })
        guard case .rect(let rect) = restored.geometry else {
            Issue.record("cancel must restore the rect")
            return
        }
        #expect(abs(rect.origin.x - 3.0) < 1e-9)
        #expect(viewModel.violations.isEmpty)
        expectLiveMatchesBatch(viewModel, "after cancel")
    }

    // MARK: - Undo/redo resync

    @Test func undoRedoResyncLiveSession() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.selectedShapeIDs = [fixture.rover.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: -1.9, y: 0))
        #expect(viewModel.violations.contains { $0.kind == .minSpacing })

        viewModel.undo()
        #expect(viewModel.violations.isEmpty, "undo must re-verify the restored document")
        expectLiveMatchesBatch(viewModel, "after undo")

        viewModel.redo()
        #expect(viewModel.violations.contains { $0.kind == .minSpacing })
        expectLiveMatchesBatch(viewModel, "after redo")
    }

    // MARK: - Mode transitions

    @Test func drdOffSuspendsLiveVerification() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.drdMode = .off
        #expect(viewModel.violations.isEmpty)

        viewModel.selectedShapeIDs = [fixture.rover.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: -1.9, y: 0))
        #expect(
            viewModel.violations.isEmpty,
            "with DRD off, edits must not update violations"
        )

        // On-demand run still works through the batch path.
        viewModel.runDRC()
        #expect(viewModel.violations.contains { $0.kind == .minSpacing })

        // Re-enabling live mode resyncs from the current document.
        viewModel.drdMode = .observe
        expectLiveMatchesBatch(viewModel, "after re-enabling observe")
    }
}
