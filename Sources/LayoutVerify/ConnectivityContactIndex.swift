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
    private let maximumEntries: Int
    private var entryCount = 0
    var storedEntryCount: Int { entryCount }
    private var cells: [CellKey: [ConnectivityElementKey]] = [:]

    init(cellSize: Double, maximumEntries: Int) {
        self.cellSize = max(cellSize, 1e-9)
        self.maximumEntries = maximumEntries
    }

    @discardableResult
    mutating func insert(_ key: ConnectivityElementKey, boundingBox: LayoutRect) throws -> Int {
        let span = try cellSpan(of: boundingBox)
        guard span.count <= maximumEntries - entryCount else {
            throw LayoutConductorCaptureError.limitExceeded(.spatialIndexEntries)
        }
        for cx in span.x {
            for cy in span.y {
                cells[CellKey(x: cx, y: cy), default: []].append(key)
            }
        }
        entryCount += span.count
        return span.count
    }

    @discardableResult
    mutating func remove(_ key: ConnectivityElementKey, boundingBox: LayoutRect) throws -> Int {
        let span = try cellSpan(of: boundingBox)
        for cx in span.x {
            for cy in span.y {
                let cellKey = CellKey(x: cx, y: cy)
                guard let index = cells[cellKey]?.firstIndex(of: key) else {
                    throw LayoutConductorCaptureError.invalidComposition
                }
                cells[cellKey]?.remove(at: index)
                if cells[cellKey]?.isEmpty == true {
                    cells.removeValue(forKey: cellKey)
                }
            }
        }
        entryCount -= span.count
        return span.count
    }

    /// Every element whose covered cells intersect the probe box's cells —
    /// a superset of the elements whose bounding boxes intersect the probe.
    func candidates(near boundingBox: LayoutRect) throws -> (keys: Set<ConnectivityElementKey>, cellVisits: Int) {
        let span = try cellSpan(of: boundingBox)
        var found: Set<ConnectivityElementKey> = []
        for cx in span.x {
            for cy in span.y {
                if let members = cells[CellKey(x: cx, y: cy)] {
                    found.formUnion(members)
                }
            }
        }
        return (found, span.count)
    }

    func entryCost(near boundingBox: LayoutRect) throws -> Int { try cellSpan(of: boundingBox).count }

    private func cellSpan(of box: LayoutRect) throws -> (x: ClosedRange<Int64>, y: ClosedRange<Int64>, count: Int) {
        guard maximumEntries >= 0, cellSize.isFinite, cellSize > 0,
              let cxMin = Int64(exactly: (box.minX / cellSize).rounded(.down)),
              let cxMax = Int64(exactly: (box.maxX / cellSize).rounded(.down)),
              let cyMin = Int64(exactly: (box.minY / cellSize).rounded(.down)),
              let cyMax = Int64(exactly: (box.maxY / cellSize).rounded(.down)),
              cxMin <= cxMax, cyMin <= cyMax else { throw LayoutConductorCaptureError.invalidSpatialBounds }
        let xDifference = cxMax.subtractingReportingOverflow(cxMin)
        let yDifference = cyMax.subtractingReportingOverflow(cyMin)
        let width = xDifference.partialValue.addingReportingOverflow(1)
        let height = yDifference.partialValue.addingReportingOverflow(1)
        let cells = width.partialValue.multipliedReportingOverflow(by: height.partialValue)
        guard !xDifference.overflow, !yDifference.overflow, !width.overflow, !height.overflow,
              !cells.overflow, let count = Int(exactly: cells.partialValue), count <= maximumEntries else {
            throw LayoutConductorCaptureError.limitExceeded(.spatialIndexEntries)
        }
        return (cxMin...cxMax, cyMin...cyMax, count)
    }
}
