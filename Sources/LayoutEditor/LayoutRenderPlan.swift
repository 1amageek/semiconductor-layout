import Foundation
import LayoutCore

/// What the canvas draws for one viewport at one zoom level, produced by
/// `LayoutRenderIndex.plan(viewport:pixelsPerMicron:options:)`.
///
/// Shapes land in one of three level-of-detail tiers by their on-screen
/// size: full geometry, bounding-box-only, or — below one pixel — a
/// density aggregate. When a frame would have to visit more shapes than
/// `Options.visitBudget`, the plan falls back to per-cell aggregates
/// without visiting shapes at all; `stats.usedCellAggregates` reports
/// that fallback explicitly so it is never mistaken for a fully-drawn
/// frame.
public struct LayoutRenderPlan: Sendable {

    /// Level-of-detail policy knobs, all in screen pixels except the
    /// visit budget.
    public struct Options: Sendable {
        /// Shapes at least this large on screen draw their full geometry.
        public var fullThresholdPx: Double
        /// Shapes at least this large draw as bounding boxes; smaller
        /// ones aggregate into density tiles.
        public var boxThresholdPx: Double
        /// Upper bound on shapes visited per plan; beyond it the plan
        /// falls back to per-cell aggregates to keep frame time bounded.
        /// The budget alone drives the fallback — a screen-size trigger
        /// would also fire on small designs at fit-all zoom and collapse
        /// shapes that are perfectly drawable.
        public var visitBudget: Int

        public init(
            fullThresholdPx: Double = 4,
            boxThresholdPx: Double = 1,
            visitBudget: Int = 200_000
        ) {
            self.fullThresholdPx = fullThresholdPx
            self.boxThresholdPx = boxThresholdPx
            self.visitBudget = visitBudget
        }
    }

    /// Per-layer draw work: full-geometry shapes plus bounding-box-only
    /// rects, so the canvas keeps its one-fill-per-layer pipeline.
    public struct LayerBatch: Sendable {
        public var layer: LayoutLayerID
        public var fullShapes: [LayoutShape]
        public var boxRects: [LayoutRect]
    }

    /// A density tile: shapes too small to draw individually, collapsed
    /// into their grid cell with an exact occupied-area fraction.
    public struct Aggregate: Sendable, Equatable {
        public var layer: LayoutLayerID
        public var rect: LayoutRect
        /// Occupied-area fraction of `rect` in [0, 1], from the summed
        /// (cell-clipped) bounding-box areas of the aggregated shapes.
        public var density: Double

        public init(layer: LayoutLayerID, rect: LayoutRect, density: Double) {
            self.layer = layer
            self.rect = rect
            self.density = density
        }
    }

    /// Honest accounting of what this plan covers and what it collapsed.
    public struct Stats: Sendable, Equatable {
        /// Shapes the index holds in total, visible or not.
        public var totalShapes: Int
        /// Grid cells inspected for this viewport.
        public var visitedCellCount: Int
        /// Shapes drawn with full geometry.
        public var fullCount: Int
        /// Shapes drawn as bounding boxes.
        public var boxCount: Int
        /// Shape-cell incidences collapsed into aggregates. In cell-
        /// aggregate fallback mode a shape spanning several cells counts
        /// once per cell, so this is an upper bound on distinct shapes.
        public var aggregatedCount: Int
        /// True when the plan skipped shape visits entirely (visit
        /// budget exceeded) and drew per-cell aggregates.
        public var usedCellAggregates: Bool
    }

    /// Batches in deterministic layer order (name, then purpose).
    public var batches: [LayerBatch]
    public var aggregates: [Aggregate]
    public var stats: Stats

    /// A plan that draws nothing (empty index or degenerate viewport).
    public static func empty(totalShapes: Int = 0) -> LayoutRenderPlan {
        LayoutRenderPlan(
            batches: [],
            aggregates: [],
            stats: Stats(
                totalShapes: totalShapes,
                visitedCellCount: 0,
                fullCount: 0,
                boxCount: 0,
                aggregatedCount: 0,
                usedCellAggregates: false
            )
        )
    }
}
