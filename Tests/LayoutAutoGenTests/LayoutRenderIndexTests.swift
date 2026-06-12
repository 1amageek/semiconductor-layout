import Foundation
import Testing
import LayoutCore
import LayoutVerify
import LayoutEditor

/// Unit oracle for the M6 render index: viewport culling, the three
/// level-of-detail tiers, density arithmetic, the visit-budget fallback,
/// and — the property everything else leans on — that incremental
/// `apply(_:)` produces plans identical to an index built fresh from the
/// final geometry. Coordinates are integers and cell sizes explicit so
/// every expectation is float-exact.
@Suite("LayoutRenderIndex", .timeLimit(.minutes(5)))
struct LayoutRenderIndexTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private static let m2 = LayoutLayerID(name: "M2", purpose: "drawing")

    private static func shape(
        _ x: Double, _ y: Double, _ w: Double, _ h: Double,
        layer: LayoutLayerID = m1
    ) -> LayoutShape {
        LayoutShape(layer: layer, geometry: .rect(LayoutRect(
            origin: LayoutPoint(x: x, y: y),
            size: LayoutSize(width: w, height: h)
        )))
    }

    private static func viewport(
        _ x: Double, _ y: Double, _ w: Double, _ h: Double
    ) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: x, y: y),
            size: LayoutSize(width: w, height: h)
        )
    }

    // MARK: - Plan projections (order-free comparison)

    private func fullIDs(_ plan: LayoutRenderPlan) -> Set<UUID> {
        Set(plan.batches.flatMap { $0.fullShapes.map(\.id) })
    }

    private func boxRects(_ plan: LayoutRenderPlan) -> [LayoutRect] {
        plan.batches.flatMap(\.boxRects).sorted {
            ($0.origin.x, $0.origin.y, $0.size.width, $0.size.height)
                < ($1.origin.x, $1.origin.y, $1.size.width, $1.size.height)
        }
    }

    // MARK: - Culling

    @Test func viewportCullingIsExact() {
        let inside = Self.shape(10, 10, 5, 5)
        let touching = Self.shape(28, 10, 5, 5)   // straddles the right edge
        let outside = Self.shape(100, 100, 5, 5)
        let index = LayoutRenderIndex(
            shapes: [inside, touching, outside],
            cellSize: 10
        )

        let plan = index.plan(viewport: Self.viewport(0, 0, 30, 30), pixelsPerMicron: 10)
        #expect(fullIDs(plan) == [inside.id, touching.id])
        #expect(plan.stats.fullCount == 2)
        #expect(plan.stats.totalShapes == 3)
        #expect(plan.stats.usedCellAggregates == false)
        #expect(plan.aggregates.isEmpty)
    }

    @Test func shapeSpanningManyCellsIsVisitedOnce() {
        let wide = Self.shape(0, 0, 35, 2)        // spans cells 0...3 at cellSize 10
        let index = LayoutRenderIndex(shapes: [wide], cellSize: 10)

        let plan = index.plan(viewport: Self.viewport(0, 0, 40, 10), pixelsPerMicron: 10)
        #expect(plan.stats.fullCount == 1, "the seen-set must dedupe multi-cell shapes")
        #expect(fullIDs(plan) == [wide.id])
    }

    @Test func disjointViewportPlansEmpty() {
        let index = LayoutRenderIndex(shapes: [Self.shape(0, 0, 5, 5)], cellSize: 10)
        let plan = index.plan(viewport: Self.viewport(1000, 1000, 50, 50), pixelsPerMicron: 10)
        #expect(plan.batches.isEmpty)
        #expect(plan.aggregates.isEmpty)
        #expect(plan.stats.totalShapes == 1)
        #expect(plan.stats.fullCount == 0)
    }

    @Test func emptyIndexPlansEmpty() {
        let index = LayoutRenderIndex(shapes: [], cellSize: 10)
        #expect(index.count == 0)
        #expect(index.occupiedBounds == nil)
        let plan = index.plan(viewport: Self.viewport(0, 0, 100, 100), pixelsPerMicron: 1)
        #expect(plan.batches.isEmpty)
        #expect(plan.stats.totalShapes == 0)
    }

    @Test func emptyExtentDerivedGridAcceptsFirstShapeCheaply() {
        // Regression: deriving the grid from an empty document used to
        // bottom out at the 1e-6 µm cell-size floor, so the first real
        // shape spanned ~1e16 cells and `insert` spun forever. The suite
        // time limit is the hang oracle; the expectations pin behavior.
        var index = LayoutRenderIndex(shapes: [])
        let first = Self.shape(0, 0, 100, 100)
        index.apply(LayoutEditDelta(addedShapes: [first]))
        #expect(index.count == 1)
        let plan = index.plan(viewport: Self.viewport(0, 0, 100, 100), pixelsPerMicron: 10)
        #expect(fullIDs(plan) == [first.id])
    }

    // MARK: - Level-of-detail tiers

    @Test func tiersSplitByOnScreenSizeAtExactThresholds() {
        // At 0.5 px/um with the default thresholds (full >= 4px, box >=
        // 1px): 8um -> exactly 4px (full), 2um -> 1px (box, boundary
        // inclusive), 1um -> 0.5px (micro aggregate).
        let big = Self.shape(0, 0, 8, 8)
        let small = Self.shape(20, 0, 2, 2)
        let micro = Self.shape(34, 4, 1, 1)
        let index = LayoutRenderIndex(shapes: [big, small, micro], cellSize: 10)

        let plan = index.plan(viewport: Self.viewport(0, 0, 40, 10), pixelsPerMicron: 0.5)
        #expect(fullIDs(plan) == [big.id])
        #expect(plan.stats.fullCount == 1)
        #expect(plan.stats.boxCount == 1)
        #expect(plan.stats.aggregatedCount == 1)
        #expect(plan.stats.usedCellAggregates == false)
        #expect(boxRects(plan) == [LayoutRect(
            origin: LayoutPoint(x: 20, y: 0),
            size: LayoutSize(width: 2, height: 2)
        )])

        // The micro shape lands in the density tile of its center cell
        // (3,0) with its full bbox area over the cell area: 1 / 100.
        #expect(plan.aggregates == [LayoutRenderPlan.Aggregate(
            layer: Self.m1,
            rect: LayoutRect(
                origin: LayoutPoint(x: 30, y: 0),
                size: LayoutSize(width: 10, height: 10)
            ),
            density: 0.01
        )])
    }

    @Test func microShapesAccumulateIntoTheirCenterCellTile() {
        // Two 1x1 micro shapes centered in cell (0,0): densities add.
        let a = Self.shape(1, 1, 1, 1)
        let b = Self.shape(4, 4, 1, 1)
        let index = LayoutRenderIndex(shapes: [a, b], cellSize: 10)

        let plan = index.plan(viewport: Self.viewport(0, 0, 10, 10), pixelsPerMicron: 0.5)
        #expect(plan.stats.aggregatedCount == 2)
        #expect(plan.aggregates == [LayoutRenderPlan.Aggregate(
            layer: Self.m1,
            rect: LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 10, height: 10)
            ),
            density: 0.02
        )])
    }

    @Test func zoomMovesTheSameShapeAcrossTiers() {
        let shape = Self.shape(0, 0, 2, 2)
        let index = LayoutRenderIndex(shapes: [shape], cellSize: 10)
        let viewport = Self.viewport(0, 0, 10, 10)

        #expect(index.plan(viewport: viewport, pixelsPerMicron: 2).stats.fullCount == 1)
        #expect(index.plan(viewport: viewport, pixelsPerMicron: 1).stats.boxCount == 1)
        #expect(index.plan(viewport: viewport, pixelsPerMicron: 0.25).stats.aggregatedCount == 1)
    }

    // MARK: - Visit-budget fallback

    @Test func visitBudgetFallsBackToCellAggregates() {
        // Five unit squares in cell (0,0), one in cell (1,0); budget 3
        // forces the no-visit fallback with exact per-cell densities.
        let crowded = (0..<5).map { Self.shape(Double($0 * 2), 0, 1, 1) }
        let lone = Self.shape(12, 0, 1, 1)
        let index = LayoutRenderIndex(shapes: crowded + [lone], cellSize: 10)

        let options = LayoutRenderPlan.Options(visitBudget: 3)
        let plan = index.plan(
            viewport: Self.viewport(0, 0, 20, 10),
            pixelsPerMicron: 10,
            options: options
        )
        #expect(plan.stats.usedCellAggregates == true)
        #expect(plan.batches.isEmpty, "fallback mode visits no shapes")
        #expect(plan.stats.aggregatedCount == 6)
        #expect(plan.aggregates == [
            LayoutRenderPlan.Aggregate(
                layer: Self.m1,
                rect: LayoutRect(
                    origin: LayoutPoint(x: 0, y: 0),
                    size: LayoutSize(width: 10, height: 10)
                ),
                density: 0.05
            ),
            LayoutRenderPlan.Aggregate(
                layer: Self.m1,
                rect: LayoutRect(
                    origin: LayoutPoint(x: 10, y: 0),
                    size: LayoutSize(width: 10, height: 10)
                ),
                density: 0.01
            ),
        ])
    }

    @Test func fallbackClipsSpanningShapesPerCell() {
        // One 20x5 rect spanning cells (0,0) and (1,0) evenly: each cell
        // sees a clipped area of 50, and the shape counts once per cell
        // in `aggregatedCount` (the documented upper bound).
        let spanning = Self.shape(0, 0, 20, 5)
        let index = LayoutRenderIndex(shapes: [spanning], cellSize: 10)

        let plan = index.plan(
            viewport: Self.viewport(0, 0, 20, 10),
            pixelsPerMicron: 10,
            options: LayoutRenderPlan.Options(visitBudget: 0)
        )
        #expect(plan.stats.usedCellAggregates == true)
        #expect(plan.stats.aggregatedCount == 2)
        #expect(plan.aggregates.map(\.density) == [0.5, 0.5])
    }

    @Test func smallDesignAtFitAllZoomStaysExact() {
        // The regression the budget-only fallback rule protects: a tiny
        // design fully zoomed out must still draw real geometry, not
        // density tiles, no matter how small the grid cells are on
        // screen.
        let shapes = (0..<10).map { Self.shape(Double($0 * 2), 0, 1, 1) }
        let index = LayoutRenderIndex(shapes: shapes, cellSize: 0.25)
        let plan = index.plan(
            viewport: Self.viewport(-100, -100, 220, 210),
            pixelsPerMicron: 5
        )
        #expect(plan.stats.usedCellAggregates == false)
        #expect(plan.stats.fullCount == 10)
    }

    // MARK: - Layer batches

    @Test func batchesAreSortedByLayerAndSplitCorrectly() {
        let a = Self.shape(0, 0, 5, 5, layer: Self.m2)
        let b = Self.shape(10, 0, 5, 5, layer: Self.m1)
        let index = LayoutRenderIndex(shapes: [a, b], cellSize: 10)

        let plan = index.plan(viewport: Self.viewport(0, 0, 20, 10), pixelsPerMicron: 10)
        #expect(plan.batches.map(\.layer) == [Self.m1, Self.m2])
        #expect(plan.batches[0].fullShapes.map(\.id) == [b.id])
        #expect(plan.batches[1].fullShapes.map(\.id) == [a.id])
    }

    // MARK: - Incremental maintenance

    /// The load-bearing property: after any delta sequence the index
    /// plans exactly like one built fresh from the final geometry.
    @Test func applyMatchesAFreshBuildAfterAddUpdateRemove() {
        var shapes = (0..<20).map { Self.shape(Double($0 % 5) * 7, Double($0 / 5) * 7, 3, 3) }
        var index = LayoutRenderIndex(shapes: shapes, cellSize: 10)

        // Remove four, move four across cells, add four on another layer.
        let removed = Array(shapes[0..<4])
        shapes.removeFirst(4)
        var moved: [LayoutShape] = []
        for i in 0..<4 {
            var copy = shapes[i]
            copy.geometry = copy.geometry.translated(by: LayoutPoint(x: 13, y: 13))
            moved.append(copy)
            shapes[i] = copy
        }
        let added = (0..<4).map { Self.shape(Double($0) * 9, 40, 2, 2, layer: Self.m2) }
        shapes.append(contentsOf: added)

        index.apply(LayoutEditDelta(
            addedShapes: added,
            updatedShapes: moved,
            removedShapeIDs: removed.map(\.id)
        ))

        let fresh = LayoutRenderIndex(shapes: shapes, cellSize: 10)
        #expect(index.count == fresh.count)

        // Compare across zooms so every tier and both walk strategies
        // get exercised.
        let viewports = [
            Self.viewport(0, 0, 50, 50),
            Self.viewport(5, 5, 12, 12),
            Self.viewport(-20, -20, 100, 100),
        ]
        for viewport in viewports {
            for ppm in [0.2, 1.0, 10.0] {
                let live = index.plan(viewport: viewport, pixelsPerMicron: ppm)
                let reference = fresh.plan(viewport: viewport, pixelsPerMicron: ppm)
                #expect(fullIDs(live) == fullIDs(reference), "\(viewport) @\(ppm)")
                #expect(boxRects(live) == boxRects(reference), "\(viewport) @\(ppm)")
                #expect(live.aggregates == reference.aggregates, "\(viewport) @\(ppm)")
                #expect(live.stats == reference.stats, "\(viewport) @\(ppm)")
            }
        }
    }

    @Test func unknownUpdateInsertsAndUnknownRemovalIsANoOp() {
        var index = LayoutRenderIndex(shapes: [Self.shape(0, 0, 5, 5)], cellSize: 10)

        index.apply(LayoutEditDelta(removedShapeIDs: [UUID()]))
        #expect(index.count == 1, "removing an unknown id must change nothing")

        let stranger = Self.shape(20, 0, 5, 5)
        index.apply(LayoutEditDelta(updatedShapes: [stranger]))
        #expect(index.count == 2, "updating an unknown shape inserts it")
        let plan = index.plan(viewport: Self.viewport(0, 0, 30, 10), pixelsPerMicron: 10)
        #expect(fullIDs(plan).contains(stranger.id))
    }

    @Test func updateMovingAcrossCellsLeavesNoResidue() {
        let shape = Self.shape(1, 1, 2, 2)
        var index = LayoutRenderIndex(shapes: [shape], cellSize: 10)

        var moved = shape
        moved.geometry = shape.geometry.translated(by: LayoutPoint(x: 30, y: 0))
        index.apply(LayoutEditDelta(updatedShapes: [moved]))

        let oldCell = index.plan(viewport: Self.viewport(0, 0, 10, 10), pixelsPerMicron: 10)
        #expect(oldCell.stats.fullCount == 0, "the origin cell must be empty after the move")
        #expect(oldCell.aggregates.isEmpty)
        let newCell = index.plan(viewport: Self.viewport(30, 0, 10, 10), pixelsPerMicron: 10)
        #expect(fullIDs(newCell) == [moved.id])
    }

    // MARK: - Occupied bounds

    @Test func occupiedBoundsCoverTheContentAndAreMonotone() {
        let near = Self.shape(2, 2, 4, 4)
        let far = Self.shape(95, 95, 4, 4)
        var index = LayoutRenderIndex(shapes: [near, far], cellSize: 10)

        #expect(index.occupiedBounds == LayoutRect(
            origin: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 100, height: 100)
        ))

        // Removal does not shrink the outer bounds (documented monotone
        // overestimate) — but emptying the index reports nil, never a
        // stale extent.
        index.apply(LayoutEditDelta(removedShapeIDs: [far.id]))
        #expect(index.occupiedBounds == LayoutRect(
            origin: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 100, height: 100)
        ))
        index.apply(LayoutEditDelta(removedShapeIDs: [near.id]))
        #expect(index.occupiedBounds == nil)
    }

    @Test func derivedCellSizeTargetsTheConfiguredCellCount() {
        // Extent 0...100 in x with targetCellsPerAxis 10 -> cellSize 10:
        // verifiable through the aggregate tile geometry.
        let shapes = [Self.shape(0, 0, 1, 1), Self.shape(99, 0, 1, 1)]
        let index = LayoutRenderIndex(shapes: shapes, targetCellsPerAxis: 10)
        let plan = index.plan(
            viewport: Self.viewport(0, 0, 100, 10),
            pixelsPerMicron: 10,
            options: LayoutRenderPlan.Options(visitBudget: 0)
        )
        #expect(plan.aggregates.map(\.rect) == [
            LayoutRect(origin: LayoutPoint(x: 0, y: 0), size: LayoutSize(width: 10, height: 10)),
            LayoutRect(origin: LayoutPoint(x: 90, y: 0), size: LayoutSize(width: 10, height: 10)),
        ])
    }
}
