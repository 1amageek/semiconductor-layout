import Foundation
import LayoutCore
import LayoutVerify

/// Mutable uniform-grid index over (flattened) shape bounding boxes that
/// answers "what should the canvas draw for this viewport at this zoom"
/// in time proportional to the visible cells and the visible shapes —
/// never the whole database — so editing stays interactive at
/// million-shape scale.
///
/// Each occupied cell keeps, per layer, the exact shape count and the sum
/// of cell-clipped bounding-box areas. Both are additive, so incremental
/// `apply(_:)` keeps them exact under add/update/remove without ever
/// rescanning, and a zoomed-out frame can emit density aggregates from
/// the cell statistics alone without visiting a single shape.
///
/// The grid geometry (cell size and origin) is fixed at build time from
/// the initial extent; shapes edited or added outside that extent simply
/// hash to new cells. Structural changes (instances, cell navigation)
/// require a fresh index, mirroring `IncrementalDRCSession.rebuild`.
public struct LayoutRenderIndex {

    private struct CellKey: Hashable {
        var x: Int64
        var y: Int64
    }

    private struct LayerAggregate {
        var count: Int = 0
        var areaSum: Double = 0

        mutating func add(_ clippedArea: Double) {
            count += 1
            areaSum += clippedArea
        }

        mutating func subtract(_ clippedArea: Double) {
            count -= 1
            areaSum -= clippedArea
        }
    }

    private struct Bucket {
        var ids: [UUID] = []
        var perLayer: [LayoutLayerID: LayerAggregate] = [:]

        mutating func add(_ id: UUID, layer: LayoutLayerID, clippedArea: Double) {
            ids.append(id)
            perLayer[layer, default: LayerAggregate()].add(clippedArea)
        }

        /// Returns true when the bucket holds nothing afterwards.
        mutating func removeEntry(
            _ id: UUID,
            layer: LayoutLayerID,
            clippedArea: Double
        ) -> Bool {
            if let position = ids.firstIndex(of: id) {
                ids.remove(at: position)
            }
            if let aggregate = perLayer[layer] {
                if aggregate.count <= 1 {
                    perLayer.removeValue(forKey: layer)
                } else {
                    perLayer[layer, default: LayerAggregate()].subtract(clippedArea)
                }
            }
            return ids.isEmpty
        }
    }

    private struct Entry {
        var shape: LayoutShape
        var bounds: LayoutRect
    }

    private var entries: [UUID: Entry] = [:]
    private var cells: [CellKey: Bucket] = [:]
    private let cellSize: Double
    // Monotone outer bounds of occupied cells; they never shrink on
    // removal, which only costs a few extra empty-cell probes per frame.
    private var minCellX = Int64.max
    private var maxCellX = Int64.min
    private var minCellY = Int64.max
    private var maxCellY = Int64.min

    /// Number of shapes the index holds.
    public var count: Int { entries.count }

    /// Outer bounds of all occupied grid cells — an O(1) over-
    /// approximation of the content extent by at most one cell per side.
    /// Monotone: removals never shrink it until the index is rebuilt,
    /// which overview framing tolerates and exact framing must not rely
    /// on.
    public var occupiedBounds: LayoutRect? {
        guard !entries.isEmpty, minCellX <= maxCellX, minCellY <= maxCellY else { return nil }
        return LayoutRect(
            origin: LayoutPoint(
                x: Double(minCellX) * cellSize,
                y: Double(minCellY) * cellSize
            ),
            size: LayoutSize(
                width: Double(maxCellX - minCellX + 1) * cellSize,
                height: Double(maxCellY - minCellY + 1) * cellSize
            )
        )
    }

    /// Builds the grid from the shapes' joint extent so roughly
    /// `targetCellsPerAxis` cells span the longer axis; `cellSize`
    /// overrides that derivation (tests pin it for exact arithmetic).
    public init(
        shapes: [LayoutShape],
        targetCellsPerAxis: Int = 256,
        cellSize: Double? = nil
    ) {
        if let cellSize {
            self.cellSize = max(cellSize, 1e-9)
        } else {
            var extent: LayoutRect?
            for shape in shapes {
                let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
                extent = extent.map { $0.union(box) } ?? box
            }
            let longerAxis = extent.map { max($0.size.width, $0.size.height) } ?? 0
            if longerAxis > 0 {
                self.cellSize = max(longerAxis / Double(max(targetCellsPerAxis, 1)), 1e-6)
            } else {
                // Empty or zero-area content gives no scale to derive a
                // grid from. The grid is fixed at build time, so a tiny
                // placeholder cell (1e-6 µm) would make the first real
                // shape span ~1e16 cells and spin `insert` forever; one
                // micron keeps inserts cheap until the owner rebuilds
                // over real content.
                self.cellSize = 1.0
            }
        }
        entries.reserveCapacity(shapes.count)
        for shape in shapes {
            insert(shape)
        }
    }

    /// Applies a geometry-level edit. Updated shapes the index does not
    /// hold are inserted (delta order), unknown removals are no-ops —
    /// the same tolerance `IncrementalDRCSession` documents. Via fields
    /// are deliberately ignored: the index holds shapes only, because the
    /// canvas does not draw vias from the flattened stream.
    public mutating func apply(_ delta: LayoutEditDelta) {
        for id in delta.removedShapeIDs {
            remove(id)
        }
        for shape in delta.updatedShapes {
            remove(shape.id)
            insert(shape)
        }
        for shape in delta.addedShapes {
            remove(shape.id)
            insert(shape)
        }
    }

    // MARK: - Planning

    /// The draw plan for `viewport` (micron space) rendered at
    /// `pixelsPerMicron`. See `LayoutRenderPlan` for tier semantics.
    public func plan(
        viewport: LayoutRect,
        pixelsPerMicron: Double,
        options: LayoutRenderPlan.Options = LayoutRenderPlan.Options()
    ) -> LayoutRenderPlan {
        guard !entries.isEmpty, pixelsPerMicron > 0,
              viewport.size.width >= 0, viewport.size.height >= 0,
              minCellX <= maxCellX else {
            return .empty(totalShapes: entries.count)
        }

        // Visible cell range, clamped to the occupied outer bounds so a
        // fully zoomed-out viewport never walks empty space.
        let xRange = cellRange(viewport.minX, viewport.maxX)
        let yRange = cellRange(viewport.minY, viewport.maxY)
        let cxMin = max(xRange.lowerBound, minCellX)
        let cxMax = min(xRange.upperBound, maxCellX)
        let cyMin = max(yRange.lowerBound, minCellY)
        let cyMax = min(yRange.upperBound, maxCellY)
        guard cxMin <= cxMax, cyMin <= cyMax else {
            return .empty(totalShapes: entries.count)
        }

        // Walk whichever is smaller: the cell range or the occupied set.
        var visibleCells: [(CellKey, Bucket)] = []
        let rangeCount = (cxMax - cxMin + 1) * (cyMax - cyMin + 1)
        if rangeCount <= Int64(cells.count) {
            for cx in cxMin...cxMax {
                for cy in cyMin...cyMax {
                    let key = CellKey(x: cx, y: cy)
                    if let bucket = cells[key] {
                        visibleCells.append((key, bucket))
                    }
                }
            }
        } else {
            for (key, bucket) in cells
            where key.x >= cxMin && key.x <= cxMax && key.y >= cyMin && key.y <= cyMax {
                visibleCells.append((key, bucket))
            }
        }

        var estimatedVisit = 0
        for (_, bucket) in visibleCells {
            estimatedVisit += bucket.ids.count
        }

        let cellArea = cellSize * cellSize
        var stats = LayoutRenderPlan.Stats(
            totalShapes: entries.count,
            visitedCellCount: visibleCells.count,
            fullCount: 0,
            boxCount: 0,
            aggregatedCount: 0,
            usedCellAggregates: false
        )

        if estimatedVisit > options.visitBudget {
            // Cell-aggregate fallback: density tiles straight from the
            // per-cell statistics, no shape visits.
            stats.usedCellAggregates = true
            var aggregates: [LayoutRenderPlan.Aggregate] = []
            for (key, bucket) in visibleCells {
                let rect = cellRect(key)
                for (layer, aggregate) in bucket.perLayer where aggregate.count > 0 {
                    aggregates.append(LayoutRenderPlan.Aggregate(
                        layer: layer,
                        rect: rect,
                        density: min(aggregate.areaSum / cellArea, 1)
                    ))
                    stats.aggregatedCount += aggregate.count
                }
            }
            sortAggregates(&aggregates)
            return LayoutRenderPlan(batches: [], aggregates: aggregates, stats: stats)
        }

        // Visited mode: exact viewport cull per shape, then tier by
        // on-screen size. Sub-`boxThresholdPx` shapes accumulate into
        // their center cell's density tile.
        var seen = Set<UUID>(minimumCapacity: estimatedVisit)
        var fullByLayer: [LayoutLayerID: [LayoutShape]] = [:]
        var boxByLayer: [LayoutLayerID: [LayoutRect]] = [:]
        var microTiles: [CellKey: [LayoutLayerID: LayerAggregate]] = [:]

        for (_, bucket) in visibleCells {
            for id in bucket.ids {
                guard seen.insert(id).inserted, let entry = entries[id] else { continue }
                let bounds = entry.bounds
                guard bounds.intersects(viewport) else { continue }
                let screenMax = max(bounds.size.width, bounds.size.height) * pixelsPerMicron
                if screenMax >= options.fullThresholdPx {
                    fullByLayer[entry.shape.layer, default: []].append(entry.shape)
                    stats.fullCount += 1
                } else if screenMax >= options.boxThresholdPx {
                    boxByLayer[entry.shape.layer, default: []].append(bounds)
                    stats.boxCount += 1
                } else {
                    let key = cellKey(for: bounds.center)
                    var aggregate = microTiles[key, default: [:]][entry.shape.layer]
                        ?? LayerAggregate()
                    aggregate.count += 1
                    aggregate.areaSum += bounds.size.width * bounds.size.height
                    microTiles[key, default: [:]][entry.shape.layer] = aggregate
                    stats.aggregatedCount += 1
                }
            }
        }

        var aggregates: [LayoutRenderPlan.Aggregate] = []
        for (key, perLayer) in microTiles {
            let rect = cellRect(key)
            for (layer, aggregate) in perLayer {
                aggregates.append(LayoutRenderPlan.Aggregate(
                    layer: layer,
                    rect: rect,
                    density: min(aggregate.areaSum / cellArea, 1)
                ))
            }
        }
        sortAggregates(&aggregates)

        var layers = Set(fullByLayer.keys)
        layers.formUnion(boxByLayer.keys)
        let batches = layers
            .sorted { ($0.name, $0.purpose) < ($1.name, $1.purpose) }
            .map { layer in
                LayoutRenderPlan.LayerBatch(
                    layer: layer,
                    fullShapes: fullByLayer[layer] ?? [],
                    boxRects: boxByLayer[layer] ?? []
                )
            }
        return LayoutRenderPlan(batches: batches, aggregates: aggregates, stats: stats)
    }

    // MARK: - Grid maintenance

    // Insert and remove walk the overlapped cells with direct loops, not
    // a visitor closure: a closure that mutates self while a method on
    // self is borrowing it forces a defensive copy of `cells` per call —
    // a whole-dictionary CoW copy per shape, quadratic at million-shape
    // scale (measured: a 1M-shape build took 774s before this change).
    // The defaulting/optional subscripts mutate buckets in place.

    private mutating func insert(_ shape: LayoutShape) {
        let bounds = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
        entries[shape.id] = Entry(shape: shape, bounds: bounds)
        let xRange = cellRange(bounds.minX, bounds.maxX)
        let yRange = cellRange(bounds.minY, bounds.maxY)
        for cx in xRange {
            for cy in yRange {
                let key = CellKey(x: cx, y: cy)
                let area = clippedArea(of: bounds, inCell: key)
                cells[key, default: Bucket()].add(
                    shape.id,
                    layer: shape.layer,
                    clippedArea: area
                )
                minCellX = min(minCellX, key.x)
                maxCellX = max(maxCellX, key.x)
                minCellY = min(minCellY, key.y)
                maxCellY = max(maxCellY, key.y)
            }
        }
    }

    private mutating func remove(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        let xRange = cellRange(entry.bounds.minX, entry.bounds.maxX)
        let yRange = cellRange(entry.bounds.minY, entry.bounds.maxY)
        for cx in xRange {
            for cy in yRange {
                let key = CellKey(x: cx, y: cy)
                let area = clippedArea(of: entry.bounds, inCell: key)
                // A missing bucket (unknown removal) is a documented no-op.
                let becameEmpty = cells[key]?.removeEntry(
                    id,
                    layer: entry.shape.layer,
                    clippedArea: area
                ) ?? false
                if becameEmpty {
                    cells.removeValue(forKey: key)
                }
            }
        }
    }

    /// The bounds' area clipped to one cell, so per-cell area sums stay
    /// exact under removal.
    private func clippedArea(of bounds: LayoutRect, inCell key: CellKey) -> Double {
        let rect = cellRect(key)
        let width = min(bounds.maxX, rect.maxX) - max(bounds.minX, rect.minX)
        let height = min(bounds.maxY, rect.maxY) - max(bounds.minY, rect.minY)
        return max(width, 0) * max(height, 0)
    }

    /// The closed cell range covering `[minValue, maxValue]` under a
    /// half-open convention: a maximum lying exactly on a cell boundary
    /// contributes zero area to the next cell and must not occupy it —
    /// otherwise boundary-aligned shapes leave zero-density tiles and
    /// inflate aggregate counts.
    private func cellRange(_ minValue: Double, _ maxValue: Double) -> ClosedRange<Int64> {
        let lo = Int64((minValue / cellSize).rounded(.down))
        var hi = Int64((maxValue / cellSize).rounded(.down))
        if hi > lo, Double(hi) * cellSize == maxValue {
            hi -= 1
        }
        return lo...max(hi, lo)
    }

    private func cellKey(for point: LayoutPoint) -> CellKey {
        CellKey(
            x: Int64((point.x / cellSize).rounded(.down)),
            y: Int64((point.y / cellSize).rounded(.down))
        )
    }

    private func cellRect(_ key: CellKey) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: Double(key.x) * cellSize, y: Double(key.y) * cellSize),
            size: LayoutSize(width: cellSize, height: cellSize)
        )
    }

    private func sortAggregates(_ aggregates: inout [LayoutRenderPlan.Aggregate]) {
        aggregates.sort {
            if $0.layer.name != $1.layer.name { return $0.layer.name < $1.layer.name }
            if $0.layer.purpose != $1.layer.purpose { return $0.layer.purpose < $1.layer.purpose }
            if $0.rect.origin.x != $1.rect.origin.x { return $0.rect.origin.x < $1.rect.origin.x }
            return $0.rect.origin.y < $1.rect.origin.y
        }
    }
}
