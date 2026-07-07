import LayoutCore

/// Mutable uniform-grid spatial index over conductor element bounding
/// boxes, keyed by element identity instead of array position so the live
/// session can maintain it across edits without re-sorting the table.
///
/// Cell ranges use the same closed-interval math as ``ShapeGridIndex`` on
/// both insert and query: two boxes that intersect or touch always share a
/// covered cell, so `candidates(near:)` is a strict superset of the true
/// bounding-box neighbours and the exact contact predicate stays at the
/// caller. Pruning quality depends on the cell size chosen at session
/// configure time; correctness does not.
struct ConnectivityContactIndex {

    private struct CellKey: Hashable {
        var x: Int64
        var y: Int64
    }

    private let cellSize: Double
    private var cells: [CellKey: [ConnectivityElementKey]] = [:]

    init(cellSize: Double) {
        self.cellSize = max(cellSize, 1e-9)
    }

    mutating func insert(_ key: ConnectivityElementKey, boundingBox: LayoutRect) {
        guard let span = cellSpan(of: boundingBox) else { return }
        for cx in span.x {
            for cy in span.y {
                cells[CellKey(x: cx, y: cy), default: []].append(key)
            }
        }
    }

    mutating func remove(_ key: ConnectivityElementKey, boundingBox: LayoutRect) {
        guard let span = cellSpan(of: boundingBox) else { return }
        for cx in span.x {
            for cy in span.y {
                let cellKey = CellKey(x: cx, y: cy)
                guard let index = cells[cellKey]?.firstIndex(of: key) else {
                    continue
                }
                cells[cellKey]?.remove(at: index)
                if cells[cellKey]?.isEmpty == true {
                    cells.removeValue(forKey: cellKey)
                }
            }
        }
    }

    /// Every element whose covered cells intersect the probe box's cells —
    /// a superset of the elements whose bounding boxes intersect the probe.
    func candidates(near boundingBox: LayoutRect) -> Set<ConnectivityElementKey> {
        guard let span = cellSpan(of: boundingBox) else { return [] }
        var found: Set<ConnectivityElementKey> = []
        for cx in span.x {
            for cy in span.y {
                if let members = cells[CellKey(x: cx, y: cy)] {
                    found.formUnion(members)
                }
            }
        }
        return found
    }

    private func cellSpan(of box: LayoutRect) -> (x: ClosedRange<Int64>, y: ClosedRange<Int64>)? {
        let cxMin = Int64((box.minX / cellSize).rounded(.down))
        let cxMax = Int64((box.maxX / cellSize).rounded(.down))
        let cyMin = Int64((box.minY / cellSize).rounded(.down))
        let cyMax = Int64((box.maxY / cellSize).rounded(.down))
        guard cxMin <= cxMax, cyMin <= cyMax else { return nil }
        return (cxMin...cxMax, cyMin...cyMax)
    }
}
