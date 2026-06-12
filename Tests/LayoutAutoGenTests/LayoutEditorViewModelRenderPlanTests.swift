import Foundation
import Testing
import LayoutCore
import LayoutEditor

/// Contract of the M6 scale-rendering layer inside the view model: the
/// live `LayoutRenderIndex` follows the document through every discrete
/// edit, every mid-gesture transient tick, undo/redo, and cell
/// navigation, so `currentRenderPlan()` must always equal a plan built
/// from a from-scratch index over `flattenedDocumentShapes()`.
///
/// Plans are compared as (layer, bounding box) multisets, never by shape
/// ID: flattening mints fresh UUIDs for instance-derived shapes on every
/// rebuild, so IDs differ between the live and the fresh index by design.
@MainActor
@Suite("LayoutEditorViewModel render plan", .timeLimit(.minutes(5)))
struct LayoutEditorViewModelRenderPlanTests {

    private struct Fixture {
        var viewModel: LayoutEditorViewModel
        var rich: IncrementalDRCEquivalenceHarness.RichFixture
        /// M2 pad on net A at (0.3, 0)–(0.7, 0.4).
        var padA: LayoutShape
    }

    /// Canvas 800 × 600 px at zoom 50 px/µm with no pan: the visible
    /// viewport is (0, 0)–(16, 12) µm and covers the whole fixture, and
    /// every fixture shape (smallest is 0.4 µm → 20 px) lands in the
    /// full-geometry tier.
    private static func makeFixture() throws -> Fixture {
        let rich = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let viewModel = LayoutEditorViewModel(document: rich.document, tech: rich.tech)
        viewModel.canvasSize = CGSize(width: 800, height: 600)
        viewModel.zoom = 50
        viewModel.offset = .zero
        let shapes = viewModel.documentShapes()
        return Fixture(
            viewModel: viewModel,
            rich: rich,
            padA: try #require(shapes.first { $0.layer == rich.m2 && $0.netID == rich.netA })
        )
    }

    // MARK: - Oracle

    /// A shape reduced to what rendering equivalence can honestly compare
    /// across index rebuilds: its layer and bounding box.
    private struct Stamp: Hashable {
        var layer: LayoutLayerID
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(layer: LayoutLayerID, rect: LayoutRect) {
            self.layer = layer
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }
    }

    /// Everything two plans must agree on. `visitedCellCount` is
    /// deliberately absent: a fresh index re-derives its grid from the
    /// current content extent while the live index keeps its build-time
    /// grid until the next structural rebuild, so cell-level traversal
    /// stats are not comparable after extent-changing edits — the drawn
    /// output is.
    private struct PlanProjection: Equatable {
        var fullStamps: [Stamp: Int]
        var boxStamps: [Stamp: Int]
        var aggregates: [LayoutRenderPlan.Aggregate]
        var totalShapes: Int
        var fullCount: Int
        var boxCount: Int
        var aggregatedCount: Int
        var usedCellAggregates: Bool
    }

    private func project(_ plan: LayoutRenderPlan) -> PlanProjection {
        var fullStamps: [Stamp: Int] = [:]
        var boxStamps: [Stamp: Int] = [:]
        for batch in plan.batches {
            for shape in batch.fullShapes {
                let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
                fullStamps[Stamp(layer: batch.layer, rect: box), default: 0] += 1
            }
            for rect in batch.boxRects {
                boxStamps[Stamp(layer: batch.layer, rect: rect), default: 0] += 1
            }
        }
        return PlanProjection(
            fullStamps: fullStamps,
            boxStamps: boxStamps,
            aggregates: plan.aggregates,
            totalShapes: plan.stats.totalShapes,
            fullCount: plan.stats.fullCount,
            boxCount: plan.stats.boxCount,
            aggregatedCount: plan.stats.aggregatedCount,
            usedCellAggregates: plan.stats.usedCellAggregates
        )
    }

    /// The micron viewport the view model's screen transform implies:
    /// origin −offset/zoom, size canvasSize/zoom.
    private func viewport(of viewModel: LayoutEditorViewModel) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(
                x: Double(-viewModel.offset.x / viewModel.zoom),
                y: Double(-viewModel.offset.y / viewModel.zoom)
            ),
            size: LayoutSize(
                width: Double(viewModel.canvasSize.width / viewModel.zoom),
                height: Double(viewModel.canvasSize.height / viewModel.zoom)
            )
        )
    }

    /// The live plan must equal a plan from a from-scratch index over the
    /// current flattened document, at the same viewport and scale.
    @discardableResult
    private func expectMatchesFreshIndex(
        _ viewModel: LayoutEditorViewModel,
        _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> LayoutRenderPlan {
        let live = try #require(
            viewModel.currentRenderPlan(),
            "\(context): a laid-out canvas with an active cell must plan",
            sourceLocation: sourceLocation
        )
        let fresh = LayoutRenderIndex(shapes: viewModel.flattenedDocumentShapes())
            .plan(
                viewport: viewport(of: viewModel),
                pixelsPerMicron: Double(viewModel.zoom)
            )
        #expect(
            project(live) == project(fresh),
            "\(context): live render plan must equal a from-scratch rebuild",
            sourceLocation: sourceLocation
        )
        return live
    }

    // MARK: - Baseline

    @Test func freshViewModelPlansTheWholeFixtureInFullTier() throws {
        let fixture = try Self.makeFixture()
        let plan = try expectMatchesFreshIndex(fixture.viewModel, "at init")

        // 5 top-level shapes + 2 instances × 2 child shapes, all ≥ 20 px
        // on screen and all inside the viewport.
        #expect(plan.stats.totalShapes == 9)
        #expect(plan.stats.fullCount == 9)
        #expect(plan.stats.boxCount == 0)
        #expect(plan.stats.aggregatedCount == 0)
        #expect(plan.stats.usedCellAggregates == false)
        #expect(plan.aggregates.isEmpty)
    }

    @Test func offsetAndZoomDefineTheViewport() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        // Pan so the viewport starts at x = 6 µm: only the two 8 µm M1
        // wires and the second child instance (x 6.5–7.1) remain visible.
        viewModel.offset = CGPoint(x: -300, y: 0)
        let partial = try expectMatchesFreshIndex(viewModel, "panned to x ≥ 6")
        #expect(partial.stats.fullCount == 4)

        // Pan past the content (viewport starts at x = 9 µm, content ends
        // at x = 8): nothing is visible, and the plan says so.
        viewModel.offset = CGPoint(x: -450, y: 0)
        let empty = try expectMatchesFreshIndex(viewModel, "panned past content")
        #expect(empty.stats.fullCount == 0)
        #expect(empty.batches.isEmpty)
        #expect(empty.stats.totalShapes == 9)
    }

    @Test func degenerateCanvasPlansNothing() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        viewModel.canvasSize = .zero
        #expect(
            viewModel.currentRenderPlan() == nil,
            "an un-laid-out canvas has nothing to plan against"
        )

        viewModel.canvasSize = CGSize(width: 800, height: 600)
        viewModel.zoom = 0
        #expect(viewModel.currentRenderPlan() == nil)

        viewModel.zoom = 50
        #expect(viewModel.currentRenderPlan() != nil)
    }

    @Test func firstShapeOnEmptyDocumentDerivesARealGrid() throws {
        // Regression: the default view model builds its render index over
        // an empty TOP cell, whose derived grid used to bottom out at the
        // 1e-6 µm cell-size floor — the first drawn rectangle then spun
        // `insert` across ~1e16 cells and froze the editor. The suite time
        // limit is the hang oracle; the plan equality pins correctness.
        let viewModel = LayoutEditorViewModel()
        viewModel.canvasSize = CGSize(width: 800, height: 600)
        viewModel.zoom = 50
        viewModel.offset = .zero

        viewModel.addRectangle(
            from: LayoutPoint(x: 0, y: 0),
            to: LayoutPoint(x: 100, y: 100)
        )

        let plan = try expectMatchesFreshIndex(viewModel, "first shape on empty document")
        #expect(plan.stats.totalShapes == 1)
    }

    // MARK: - Discrete edits with undo/redo

    @Test func discreteEditsKeepThePlanInLockstep() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        viewModel.activeLayer = fixture.rich.m2
        viewModel.addRectangle(
            from: LayoutPoint(x: 1, y: 5),
            to: LayoutPoint(x: 2, y: 5.5)
        )
        let afterAdd = try expectMatchesFreshIndex(viewModel, "after add")
        #expect(afterAdd.stats.totalShapes == 10)
        #expect(afterAdd.stats.fullCount == 10)

        viewModel.selectedShapeIDs = [fixture.padA.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: 0, y: 1.5))
        try expectMatchesFreshIndex(viewModel, "after move")

        viewModel.deleteSelectedShapes()
        let afterDelete = try expectMatchesFreshIndex(viewModel, "after delete")
        #expect(afterDelete.stats.totalShapes == 9)

        viewModel.undo()
        try expectMatchesFreshIndex(viewModel, "after undoing delete")
        viewModel.undo()
        try expectMatchesFreshIndex(viewModel, "after undoing move")
        viewModel.undo()
        let backToStart = try expectMatchesFreshIndex(viewModel, "after undoing add")
        #expect(backToStart.stats.totalShapes == 9)

        viewModel.redo()
        let afterRedo = try expectMatchesFreshIndex(viewModel, "after redo")
        #expect(afterRedo.stats.totalShapes == 10)
    }

    // MARK: - Transient gesture paths

    @Test func shapeDragTicksKeepThePlanLiveMidGesture() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        viewModel.selectedShapeIDs = [fixture.padA.id]
        viewModel.beginShapeDrag()
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0.9, y: 0.7))
        try expectMatchesFreshIndex(viewModel, "mid-drag tick 1")
        viewModel.updateShapeDrag(to: LayoutPoint(x: 2.0, y: 1.0))
        try expectMatchesFreshIndex(viewModel, "mid-drag tick 2")

        viewModel.cancelShapeDrag()
        try expectMatchesFreshIndex(viewModel, "after cancel")

        viewModel.beginShapeDrag()
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0.9, y: 0.7))
        viewModel.endShapeDrag()
        try expectMatchesFreshIndex(viewModel, "after committed drag")
    }

    @Test func handleDragTicksKeepThePlanLiveMidGesture() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        // Stretch pad A's right edge (edge 1 runs corner 1 → 2).
        #expect(viewModel.beginHandleDrag(
            shapeID: fixture.padA.id,
            handle: .edge(1)
        ))
        viewModel.updateHandleDrag(to: LayoutPoint(x: 0.3, y: 0))
        try expectMatchesFreshIndex(viewModel, "mid-stretch tick")
        viewModel.updateHandleDrag(to: LayoutPoint(x: -0.1, y: 0))
        try expectMatchesFreshIndex(viewModel, "mid-shrink tick")

        viewModel.cancelHandleDrag()
        try expectMatchesFreshIndex(viewModel, "after cancel")

        #expect(viewModel.beginHandleDrag(
            shapeID: fixture.padA.id,
            handle: .edge(1)
        ))
        viewModel.updateHandleDrag(to: LayoutPoint(x: 0.3, y: 0))
        viewModel.endHandleDrag()
        try expectMatchesFreshIndex(viewModel, "after committed stretch")
    }

    // MARK: - Navigation

    @Test func navigationRebuildsThePlanForTheActiveCell() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel
        let childCell = try #require(
            viewModel.editor.document.cells.first { $0.name == "UNIT" }
        )

        viewModel.openCell(childCell.id)
        let childPlan = try expectMatchesFreshIndex(viewModel, "inside child cell")
        #expect(
            childPlan.stats.totalShapes == 2,
            "the plan must cover the active cell, not the whole document"
        )

        viewModel.navigateBack()
        let topPlan = try expectMatchesFreshIndex(viewModel, "back at top")
        #expect(topPlan.stats.totalShapes == 9)
    }
}
