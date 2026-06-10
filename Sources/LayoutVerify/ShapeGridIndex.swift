import LayoutCore

/// Uniform-grid spatial index over shape bounding boxes in micron space.
///
/// Queries return the indices of boxes that could intersect a probe rect
/// expanded by `margin`, so pair scans (shorts, connectivity, via coverage)
/// only visit geometric neighbours instead of every pair. Results are a
/// superset of the true neighbours — exact predicates stay at the caller —
/// and are returned in ascending index order so callers preserve the
/// emission order of the full nested-loop scan they replace.
///
/// Cell ranges are computed over closed intervals on both insert and query,
/// so boxes that merely touch at a coordinate still share a cell and are
/// always returned as candidates of each other.
struct ShapeGridIndex {

    private struct CellKey: Hashable {
        var x: Int64
        var y: Int64
    }

    private let cellSize: Double
    private var cells: [CellKey: [Int32]] = [:]

    init(boundingBoxes: [LayoutRect], cellSize: Double) {
        self.cellSize = max(cellSize, 1e-9)
        for (index, box) in boundingBoxes.enumerated() {
            forEachCell(minX: box.minX, maxX: box.maxX, minY: box.minY, maxY: box.maxY) { key in
                cells[key, default: []].append(Int32(index))
            }
        }
    }

    /// Mean of the boxes' larger dimension: long wires then span several
    /// cells while compact shapes map to one, keeping both insert fanout
    /// and query candidate counts low without tuning per call site.
    static func defaultCellSize(for boundingBoxes: [LayoutRect]) -> Double {
        guard !boundingBoxes.isEmpty else { return 1.0 }
        var total = 0.0
        for box in boundingBoxes {
            total += max(box.size.width, box.size.height)
        }
        return max(total / Double(boundingBoxes.count), 1e-3)
    }

    /// Ascending, duplicate-free indices of boxes whose cells intersect the
    /// probe rect expanded by `margin`.
    func candidateIndices(near rect: LayoutRect, margin: Double = 0) -> [Int] {
        var found: [Int32] = []
        forEachCell(
            minX: rect.minX - margin, maxX: rect.maxX + margin,
            minY: rect.minY - margin, maxY: rect.maxY + margin
        ) { key in
            if let indices = cells[key] {
                found.append(contentsOf: indices)
            }
        }
        found.sort()
        var result: [Int] = []
        result.reserveCapacity(found.count)
        var previous: Int32? = nil
        for index in found where index != previous {
            result.append(Int(index))
            previous = index
        }
        return result
    }

    private func forEachCell(
        minX: Double, maxX: Double,
        minY: Double, maxY: Double,
        _ body: (CellKey) -> Void
    ) {
        let cxMin = Int64((minX / cellSize).rounded(.down))
        let cxMax = Int64((maxX / cellSize).rounded(.down))
        let cyMin = Int64((minY / cellSize).rounded(.down))
        let cyMax = Int64((maxY / cellSize).rounded(.down))
        guard cxMin <= cxMax, cyMin <= cyMax else { return }
        for cx in cxMin...cxMax {
            for cy in cyMin...cyMax {
                body(CellKey(x: cx, y: cy))
            }
        }
    }
}
