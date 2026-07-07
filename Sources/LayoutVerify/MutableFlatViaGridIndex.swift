import LayoutCore

/// Mutable uniform-grid index over flattened via occurrences.
///
/// The index stores caller-provided boxes, usually layer-specific via
/// enclosure halos. Queries return a deterministic superset ordered by
/// ``FlatViaKey``; exact geometry predicates stay at the caller.
struct MutableFlatViaGridIndex {
    private struct CellKey: Hashable {
        var x: Int64
        var y: Int64
    }

    private let cellSize: Double
    private var cells: [CellKey: Set<FlatViaKey>] = [:]
    private var coveredCellsByKey: [FlatViaKey: [CellKey]] = [:]

    init(
        boundingBoxes: [(key: FlatViaKey, box: LayoutRect)],
        cellSize: Double
    ) {
        self.cellSize = max(cellSize, 1e-9)
        cells.reserveCapacity(boundingBoxes.count)
        coveredCellsByKey.reserveCapacity(boundingBoxes.count)
        for entry in boundingBoxes {
            insert(key: entry.key, box: entry.box)
        }
    }

    mutating func insert(key: FlatViaKey, box: LayoutRect) {
        remove(key: key)
        let keys = cellKeys(overlapping: box)
        guard !keys.isEmpty else { return }
        coveredCellsByKey[key] = keys
        for cellKey in keys {
            cells[cellKey, default: []].insert(key)
        }
    }

    mutating func remove(key: FlatViaKey) {
        guard let keys = coveredCellsByKey.removeValue(forKey: key) else { return }
        for cellKey in keys {
            cells[cellKey]?.remove(key)
            if cells[cellKey]?.isEmpty == true {
                cells.removeValue(forKey: cellKey)
            }
        }
    }

    func neighbours(of box: LayoutRect, margin: Double = 0) -> [FlatViaKey] {
        candidateKeys(of: box, margin: margin).sorted()
    }

    func candidateKeys(of box: LayoutRect, margin: Double = 0) -> Set<FlatViaKey> {
        let probe = box.expanded(by: margin, margin)
        let keys = cellKeys(overlapping: probe)
        guard !keys.isEmpty else { return [] }
        var found: Set<FlatViaKey> = []
        for key in keys {
            if let members = cells[key] {
                found.formUnion(members)
            }
        }
        return found
    }

    private func cellKeys(overlapping box: LayoutRect) -> [CellKey] {
        guard let span = cellSpan(of: box) else { return [] }
        var keys: [CellKey] = []
        let xCount = span.x.upperBound - span.x.lowerBound + 1
        let yCount = span.y.upperBound - span.y.lowerBound + 1
        if xCount > 0, yCount > 0 {
            keys.reserveCapacity(Int(xCount * yCount))
        }
        for cx in span.x {
            for cy in span.y {
                keys.append(CellKey(x: cx, y: cy))
            }
        }
        return keys
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
