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
    private let cells: [CellKey: [Int32]]

    init(boundingBoxes: [LayoutRect], cellSize: Double) {
        let size = max(cellSize, 1e-9)
        self.cellSize = size
        // Build into a local table and assign once: inserting through a
        // self-captured closure denies the optimizer unique ownership of
        // the stored dictionary, forcing a copy-on-write of the whole
        // table per insert and turning construction quadratic.
        var table: [CellKey: [Int32]] = [:]
        for (index, box) in boundingBoxes.enumerated() {
            let cxMin = Int64((box.minX / size).rounded(.down))
            let cxMax = Int64((box.maxX / size).rounded(.down))
            let cyMin = Int64((box.minY / size).rounded(.down))
            let cyMax = Int64((box.maxY / size).rounded(.down))
            guard cxMin <= cxMax, cyMin <= cyMax else { continue }
            for cx in cxMin...cxMax {
                for cy in cyMin...cyMax {
                    table[CellKey(x: cx, y: cy), default: []].append(Int32(index))
                }
            }
        }
        cells = table
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
        let cxMin = Int64(((rect.minX - margin) / cellSize).rounded(.down))
        let cxMax = Int64(((rect.maxX + margin) / cellSize).rounded(.down))
        let cyMin = Int64(((rect.minY - margin) / cellSize).rounded(.down))
        let cyMax = Int64(((rect.maxY + margin) / cellSize).rounded(.down))
        guard cxMin <= cxMax, cyMin <= cyMax else { return [] }
        for cx in cxMin...cxMax {
            for cy in cyMin...cyMax {
                if let indices = cells[CellKey(x: cx, y: cy)] {
                    found.append(contentsOf: indices)
                }
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
}
